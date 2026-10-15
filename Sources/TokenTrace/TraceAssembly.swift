/// Limits that keep tracing from ever costing the app more than a fixed budget.
public struct TraceLimits: Sendable, Hashable {
    public var maxOpenTraces: Int
    public var maxSpansPerTrace: Int
    public var maxAttributesPerSpan: Int
    public var maxEventsPerSpan: Int
    public var maxStringValueLength: Int
    public var traceTimeoutNanos: UInt64

    public init(maxOpenTraces: Int = 64, maxSpansPerTrace: Int = 128, maxAttributesPerSpan: Int = 32,
                maxEventsPerSpan: Int = 16, maxStringValueLength: Int = 256,
                traceTimeoutNanos: UInt64 = 120_000_000_000) {
        // Clamped at both ends: a limit is a budget, and an absurd one from
        // remote config must not become an overflow later.
        self.maxOpenTraces = min(max(1, maxOpenTraces), 100_000)
        self.maxSpansPerTrace = min(max(1, maxSpansPerTrace), 100_000)
        self.maxAttributesPerSpan = min(max(0, maxAttributesPerSpan), 1_024)
        self.maxEventsPerSpan = min(max(0, maxEventsPerSpan), 1_024)
        self.maxStringValueLength = min(max(1, maxStringValueLength), 65_536)
        self.traceTimeoutNanos = max(1, traceTimeoutNanos)
    }
}

/// Counters for everything the tracer refused or repaired. Telemetry that
/// silently drops data is worse than none, so every drop is counted.
public struct AssemblyCounters: Sendable, Hashable {
    public var tracesRefused = 0
    public var spansRefused = 0
    public var lateSpans = 0
    public var unknownOrEndedSpanOperations = 0
    public var attributesRefused = 0
    public var eventsRefused = 0
    public var tracesTimedOut = 0
}

/// The span bookkeeping, as a plain value type with no concurrency of its own.
/// ``TracePipeline`` owns one inside its actor, so every rule here is tested
/// synchronously and every mutation happens in one isolation domain.
///
/// A trace completes when its root has ended **and** no span is still open.
/// A child that outlives its root keeps the trace open (a streamed response
/// often finishes after the UI interaction that started it). A span started
/// under a trace that has already completed is "late" and dropped, because
/// the trace has already been sampled and exported.
public struct TraceAssembly: Sendable {
    struct Builder: Sendable {
        let spanID: SpanID
        let parentID: SpanID?
        let name: String
        let kind: SpanKind
        let startMono: UInt64
        var attributes: [String: AttributeValue] = [:]
        var events: [SpanEvent] = []
    }

    struct OpenTrace: Sendable {
        let traceID: TraceID
        let rootSpanID: SpanID
        let remoteParentID: SpanID?
        let anchorWall: Int64
        let anchorMono: UInt64
        /// Whether the trace-id's low 56 bits are known to be random (true for
        /// ids minted here; taken from the incoming flags for continued traces).
        let idIsRandom: Bool
        /// Other vendors' `tracestate` members, propagated unchanged (W3C).
        let upstreamState: [String]
        var open: [SpanID: Builder] = [:]
        var finished: [FinishedSpan] = []
        var rootEnded = false
        var droppedSpans = 0
        var spanCount: Int { open.count + finished.count }
    }

    public let limits: TraceLimits
    private var traces: [TraceID: OpenTrace] = [:]
    /// Recently completed trace ids, bounded, to tell "late" from "unknown".
    private var recentlyCompleted: [TraceID] = []
    public private(set) var counters = AssemblyCounters()

    public init(limits: TraceLimits = TraceLimits()) { self.limits = limits }

    public var openTraceCount: Int { traces.count }

    public mutating func startTrace(name: String, kind: SpanKind, traceID: TraceID, spanID: SpanID,
                                    remoteParent: SpanID?, idIsRandom: Bool = true,
                                    upstreamState: [String] = [],
                                    nowMono: UInt64, nowWall: Int64) -> SpanHandle {
        guard traces.count < limits.maxOpenTraces, traces[traceID] == nil else {
            counters.tracesRefused += 1
            return SpanHandle(traceID: traceID, spanID: spanID, isRecording: false)
        }
        var t = OpenTrace(traceID: traceID, rootSpanID: spanID, remoteParentID: remoteParent,
                          anchorWall: nowWall, anchorMono: nowMono, idIsRandom: idIsRandom,
                          upstreamState: upstreamState)
        t.open[spanID] = Builder(spanID: spanID, parentID: remoteParent, name: name, kind: kind, startMono: nowMono)
        traces[traceID] = t
        return SpanHandle(traceID: traceID, spanID: spanID, isRecording: true)
    }

    public mutating func startSpan(name: String, kind: SpanKind, parent: SpanHandle,
                                   spanID: SpanID, nowMono: UInt64) -> SpanHandle {
        let refused = SpanHandle(traceID: parent.traceID, spanID: spanID, isRecording: false)
        guard var t = traces[parent.traceID] else {
            if recentlyCompleted.contains(parent.traceID) { counters.lateSpans += 1 } else { counters.spansRefused += 1 }
            return refused
        }
        let parentKnown = t.open[parent.spanID] != nil || t.finished.contains { $0.spanID == parent.spanID }
        guard parentKnown, t.spanCount < limits.maxSpansPerTrace, t.open[spanID] == nil else {
            counters.spansRefused += 1
            t.droppedSpans += 1
            traces[parent.traceID] = t
            return refused
        }
        t.open[spanID] = Builder(spanID: spanID, parentID: parent.spanID, name: name, kind: kind, startMono: nowMono)
        traces[parent.traceID] = t
        return SpanHandle(traceID: parent.traceID, spanID: spanID, isRecording: true)
    }

    public mutating func setAttribute(_ key: String, _ value: AttributeValue, on h: SpanHandle) {
        guard h.isRecording, var t = traces[h.traceID], var b = t.open[h.spanID] else {
            counters.unknownOrEndedSpanOperations += 1
            return
        }
        guard !key.isEmpty, key.utf8.count <= 128,
              b.attributes[key] != nil || b.attributes.count < limits.maxAttributesPerSpan else {
            counters.attributesRefused += 1
            return
        }
        b.attributes[key] = truncate(value)
        t.open[h.spanID] = b
        traces[h.traceID] = t
    }

    public mutating func addEvent(_ name: String, on h: SpanHandle, nowMono: UInt64) {
        guard h.isRecording, var t = traces[h.traceID], var b = t.open[h.spanID] else {
            counters.unknownOrEndedSpanOperations += 1
            return
        }
        guard b.events.count < limits.maxEventsPerSpan else {
            counters.eventsRefused += 1
            return
        }
        b.events.append(SpanEvent(name: name, atMono: max(nowMono, b.startMono)))
        t.open[h.spanID] = b
        traces[h.traceID] = t
    }

    /// Ends a span. Idempotent: a second `end` is counted and ignored.
    /// Returns the trace if this was the last thing keeping it open.
    public mutating func end(_ h: SpanHandle, status: SpanStatus, nowMono: UInt64) -> CompletedTrace? {
        guard h.isRecording, var t = traces[h.traceID], let b = t.open.removeValue(forKey: h.spanID) else {
            counters.unknownOrEndedSpanOperations += 1
            return nil
        }
        t.finished.append(finish(b, status: status, endMono: nowMono))
        if h.spanID == t.rootSpanID { t.rootEnded = true }
        if t.rootEnded && t.open.isEmpty {
            traces[h.traceID] = nil
            return complete(t, reason: .finished)
        }
        traces[h.traceID] = t
        return nil
    }

    /// Force-completes traces older than the timeout. Their open spans end as
    /// `.abandoned` at `nowMono`, so a hung request still produces a trace,
    /// and a trace you will want to look at.
    public mutating func sweep(nowMono: UInt64) -> [CompletedTrace] {
        let expired = traces.values
            .filter { Saturating.subtract(nowMono, $0.anchorMono) >= limits.traceTimeoutNanos }
            .sorted { $0.anchorMono < $1.anchorMono }
        var out: [CompletedTrace] = []
        for var t in expired {
            for b in t.open.values { t.finished.append(finish(b, status: .abandoned, endMono: nowMono)) }
            t.open.removeAll()
            traces[t.traceID] = nil
            counters.tracesTimedOut += 1
            out.append(complete(t, reason: .timedOut))
        }
        return out
    }

    /// True if a span of this trace has already ended with a notable status.
    /// Used to tell downstream tiers "keep this one" before the trace ends.
    public func hasNotableSpan(_ traceID: TraceID) -> Bool {
        traces[traceID]?.finished.contains { $0.status.isNotable } ?? false
    }

    /// See `OpenTrace.idIsRandom`. Unknown traces report true (we minted the id).
    public func idIsRandom(_ traceID: TraceID) -> Bool { traces[traceID]?.idIsRandom ?? true }

    public func upstreamState(_ traceID: TraceID) -> [String] { traces[traceID]?.upstreamState ?? [] }

    public func isOpen(_ h: SpanHandle) -> Bool { traces[h.traceID]?.open[h.spanID] != nil }

    // MARK: - Private

    private func finish(_ b: Builder, status: SpanStatus, endMono: UInt64) -> FinishedSpan {
        FinishedSpan(spanID: b.spanID, parentID: b.parentID, name: b.name, kind: b.kind,
                     startMono: b.startMono, endMono: max(endMono, b.startMono),
                     attributes: b.attributes, events: b.events, status: status)
    }

    private mutating func complete(_ t: OpenTrace, reason: CompletionReason) -> CompletedTrace {
        recentlyCompleted.append(t.traceID)
        let cap = Saturating.int(Saturating.multiply(Int64(limits.maxOpenTraces), 4))
        if recentlyCompleted.count > cap { recentlyCompleted.removeFirst(recentlyCompleted.count - cap) }
        let spans = t.finished.sorted {
            ($0.startMono, $0.spanID.value) < ($1.startMono, $1.spanID.value)
        }
        return CompletedTrace(traceID: t.traceID, rootSpanID: t.rootSpanID, remoteParentID: t.remoteParentID,
                              anchorWall: t.anchorWall, anchorMono: t.anchorMono, spans: spans,
                              droppedSpans: t.droppedSpans, reason: reason)
    }

    private func truncate(_ v: AttributeValue) -> AttributeValue {
        guard case .string(let s) = v, s.count > limits.maxStringValueLength else { return v }
        return .string(String(s.prefix(limits.maxStringValueLength)))
    }
}
