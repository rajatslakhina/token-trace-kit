import Foundation

/// Everything an app decides once, at launch.
public struct TracingConfiguration: Sendable {
    public var limits: TraceLimits
    public var sampling: SamplingPolicy
    public var policy: AttributePolicy
    public var prices: PriceTable
    public var buffer: BufferLimits
    /// Per-install secret for `.hash` attributes and prompt digests.
    public var hashKey: [UInt8]
    public var installID: String
    /// Correct exported timestamps into the server's timebase.
    public var applySkewCorrection: Bool
    /// Recent decisions kept for inspection (debug UI, tests).
    public var decisionLogSize: Int

    public init(limits: TraceLimits = TraceLimits(), sampling: SamplingPolicy = SamplingPolicy(),
                policy: AttributePolicy = .standard, prices: PriceTable, buffer: BufferLimits = BufferLimits(),
                hashKey: [UInt8], installID: String, applySkewCorrection: Bool = true, decisionLogSize: Int = 20) {
        self.limits = limits
        self.sampling = sampling
        self.policy = policy
        self.prices = prices
        self.buffer = buffer
        self.hashKey = hashKey
        self.installID = installID
        self.applySkewCorrection = applySkewCorrection
        self.decisionLogSize = max(1, decisionLogSize)
    }
}

/// This library's `tracestate` member.
public enum TraceStateKey {
    public static let vendor = "tokentrace"
    public static let forceKeep = "k"

    /// True if a `tracestate` header asks downstream tiers to keep the trace.
    /// Splits a `tracestate` value into members, dropping empties and our
    /// own member, keeping at most 31 so ours fits under the W3C limit of 32.
    public static func foreignMembers(_ header: String?) -> [String] {
        guard let header, header.utf8.count <= 512 else { return [] }
        let members = header.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("\(vendor)=") && $0.contains("=") }
        return Array(members.prefix(31))
    }

    public static func requestsKeep(_ header: String?) -> Bool {
        guard let header else { return false }
        return header.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces) == "\(vendor)=\(forceKeep)"
        }
    }
}

/// One completed trace and what happened to it.
public struct TraceOutcome: Sendable {
    public let traceID: TraceID
    public let feature: String
    public let decision: SamplingDecision
    public let rootDurationNanos: UInt64
    public let costPicoDollars: Int64
    public let spanCount: Int
    /// Clock offset applied to this trace's timestamps (0 if none).
    public let appliedOffsetNanos: Int64
    /// The exact spans handed to the buffer; empty when dropped.
    public let exported: [ExportedSpan]
    /// The spans as recorded, before redaction (kept only in memory, for the
    /// debug UI's before/after view; never exported).
    public let recorded: CompletedTrace
    public let bufferAccepted: Bool
}

public struct PipelineMetrics: Sendable, Hashable {
    public var assembly: AssemblyCounters
    public var redaction: RedactionCounters
    /// Kept by the sampler (whether or not the buffer then had room).
    public var tracesKept = 0
    public var tracesDropped = 0
    /// Kept by the sampler but refused by a full buffer.
    public var tracesRefusedByBuffer = 0
    public var clockSamplesRejected = 0
}

/// The tracing pipeline for one app process:
///
/// ```
/// spans ─► TraceAssembly ─► CostAttributor ─► TailSampler ─► Redactor ─► TimeBase ─► ExportBuffer ─► SpanExporter
///          (bounded)        (every trace)     (keep/drop)    (default-deny) (skew)     (bounded,       (at-least-once,
///                                                                                       priority)       dedupe by id)
/// ```
///
/// All bookkeeping lives inside this actor and is synchronous, so a trace is
/// processed atomically when its last span ends: no `await` sits between
/// "the trace completed" and "the trace was sampled, redacted and buffered",
/// except the hop into ``ExportBuffer``, which takes a finished value.
public actor TracePipeline {
    public nonisolated let configuration: TracingConfiguration
    public nonisolated let buffer: ExportBuffer
    private let clock: TraceClock
    private let ids: IDSource
    private var assembly: TraceAssembly
    private var costs: CostAttributor
    private let sampler: TailSampler
    private let redactor: Redactor
    private var skew = ClockSkewEstimator()
    private var redactionCounters = RedactionCounters()
    private var kept = 0
    private var dropped = 0
    private var refusedByBuffer = 0
    private var log: [TraceOutcome] = []

    public init(configuration: TracingConfiguration, clock: TraceClock = SystemClock(),
                ids: IDSource = RandomIDSource(),
                jitter: @escaping @Sendable (UInt64) -> UInt64 = { UInt64.random(in: 0...$0) }) {
        self.configuration = configuration
        self.clock = clock
        self.ids = ids
        assembly = TraceAssembly(limits: configuration.limits)
        costs = CostAttributor(prices: configuration.prices)
        sampler = TailSampler(policy: configuration.sampling)
        redactor = Redactor(policy: configuration.policy, hashKey: configuration.hashKey)
        buffer = ExportBuffer(limits: configuration.buffer, installID: configuration.installID,
                              clock: clock, jitter: jitter)
    }

    // MARK: - Recording

    /// Starts a new trace. Span names are `StaticString` on purpose: a name
    /// built with interpolation (`"summarize \(note)"`) does not compile, so
    /// user content cannot leak through the one field redaction never sees.
    public func startTrace(_ name: StaticString, kind: SpanKind = .interaction,
                           attributes: [String: AttributeValue] = [:]) -> SpanHandle {
        let h = assembly.startTrace(name: "\(name)", kind: kind, traceID: ids.nextTraceID(),
                                    spanID: ids.nextSpanID(), remoteParent: nil,
                                    nowMono: clock.monotonicNanos, nowWall: clock.wallNanos)
        for (k, v) in attributes { assembly.setAttribute(k, v, on: h) }
        return h
    }

    /// Continues a trace that started elsewhere (a push payload, a server).
    /// An invalid header starts a fresh trace instead of being repaired.
    public func startTrace(_ name: StaticString, continuing header: String?, tracestate: String? = nil,
                           kind: SpanKind = .interaction,
                           attributes: [String: AttributeValue] = [:]) -> SpanHandle {
        guard let header, let parent = TraceParent.parse(header) else {
            return startTrace(name, kind: kind, attributes: attributes)
        }
        let h = assembly.startTrace(name: "\(name)", kind: kind, traceID: parent.traceID,
                                    spanID: ids.nextSpanID(), remoteParent: parent.parentID,
                                    idIsRandom: parent.flags.contains(.random),
                                    upstreamState: TraceStateKey.foreignMembers(tracestate),
                                    nowMono: clock.monotonicNanos, nowWall: clock.wallNanos)
        for (k, v) in attributes { assembly.setAttribute(k, v, on: h) }
        return h
    }

    public func startSpan(_ name: StaticString, kind: SpanKind = .internal, parent: SpanHandle,
                          attributes: [String: AttributeValue] = [:]) -> SpanHandle {
        let h = assembly.startSpan(name: "\(name)", kind: kind, parent: parent,
                                   spanID: ids.nextSpanID(), nowMono: clock.monotonicNanos)
        for (k, v) in attributes { assembly.setAttribute(k, v, on: h) }
        return h
    }

    public func setAttribute(_ key: String, _ value: AttributeValue, on h: SpanHandle) {
        assembly.setAttribute(key, value, on: h)
    }

    public func addEvent(_ name: StaticString, on h: SpanHandle) {
        assembly.addEvent("\(name)", on: h, nowMono: clock.monotonicNanos)
    }

    /// Records a prompt the only way it can be recorded: as a length bucket
    /// and a keyed digest.
    public func recordPrompt(_ text: SensitiveText, on h: SpanHandle) {
        assembly.setAttribute(AttributeKey.promptLengthBucket, .string(text.lengthBucket), on: h)
        assembly.setAttribute(AttributeKey.promptDigest, .string(text.digest(key: configuration.hashKey)), on: h)
    }

    /// The `traceparent` to put on an outbound request made by span `h`.
    /// `sampled` is always set: the client samples at the tail, so downstream
    /// tiers must record and apply the same rule (see ``TailSampler``).
    /// `random` is set only when the trace-id is known to be random: for a
    /// trace continued from a header without it, the flag is not invented.
    public func traceparent(for h: SpanHandle) -> String {
        let flags: TraceParent.Flags = assembly.idIsRandom(h.traceID) ? [.sampled, .random] : [.sampled]
        return TraceParent(traceID: h.traceID, parentID: h.spanID, flags: flags).headerValue
    }

    /// The `tracestate` to send with `traceparent`. When this trace has
    /// already gone wrong (a refusal, a fallback) before the request leaves,
    /// it carries `tokentrace=k`, so a server applying ratio sampling keeps
    /// its half too. Without this, the client keeps a fallback trace that the
    /// server dropped as healthy, and the waterfall has a hole in it.
    public func tracestate(for h: SpanHandle) -> String? {
        // W3C: our member goes first (we modified the trace); other vendors'
        // members are propagated unchanged.
        var members = assembly.upstreamState(h.traceID)
        if assembly.hasNotableSpan(h.traceID) {
            members.insert("\(TraceStateKey.vendor)=\(TraceStateKey.forceKeep)", at: 0)
        }
        return members.isEmpty ? nil : members.joined(separator: ",")
    }

    /// Feeds one timed exchange with your backend into the skew estimator.
    @discardableResult
    public func recordClockSample(_ s: ClockSample) -> Bool { skew.add(s) }

    public func currentSkew() -> SkewEstimate? { skew.estimate(nowMono: clock.monotonicNanos) }

    /// Ends a span; if that completes its trace, the trace is processed now.
    @discardableResult
    public func end(_ h: SpanHandle, status: SpanStatus = .ok) async -> TraceOutcome? {
        guard let trace = assembly.end(h, status: status, nowMono: clock.monotonicNanos) else { return nil }
        let (outcome, priority) = process(trace)
        return await admit(outcome, priority: priority)
    }

    /// Completes timed-out traces. Call it from a timer and on backgrounding.
    @discardableResult
    public func sweep() async -> [TraceOutcome] {
        let processed = assembly.sweep(nowMono: clock.monotonicNanos).map { process($0) }
        var out: [TraceOutcome] = []
        for (o, p) in processed { out.append(await admit(o, priority: p)) }
        return out
    }

    public func flush(to exporter: SpanExporter) async -> FlushOutcome {
        await buffer.flush(to: exporter)
    }

    // MARK: - Inspection

    public func costReport() -> [FeatureCost] { costs.report() }
    public func recentOutcomes() -> [TraceOutcome] { log }
    public func metrics() -> PipelineMetrics {
        PipelineMetrics(assembly: assembly.counters, redaction: redactionCounters, tracesKept: kept,
                        tracesDropped: dropped, tracesRefusedByBuffer: refusedByBuffer,
                        clockSamplesRejected: skew.rejectedSamples)
    }

    // MARK: - Processing (synchronous, inside the actor)

    private func process(_ trace: CompletedTrace) -> (TraceOutcome, BufferPriority?) {
        // 1. Cost first, from every trace.
        let cost = costs.record(trace)
        // 2. Sample, with the cost available as a keep reason.
        let decision = sampler.decide(trace, costPicoDollars: cost)
        var exported: [ExportedSpan] = []
        var offset: Int64 = 0
        if decision.isKept {
            kept += 1
            // 3. One offset for the whole trace, so internal ordering is preserved.
            if configuration.applySkewCorrection, let est = skew.estimate(nowMono: clock.monotonicNanos) {
                offset = est.offset(fromDeviceWall: trace.anchorWall, atMono: trace.anchorMono)
            }
            // 4. Redact and convert to wall time.
            exported = trace.spans.map { s in
                ExportedSpan(traceID: trace.traceID, spanID: s.spanID, parentID: s.parentID, name: s.name,
                             kind: s.kind,
                             startUnixNanos: wall(s.startMono, trace, offset),
                             endUnixNanos: wall(s.endMono, trace, offset),
                             attributes: redactor.redact(s.attributes, counters: &redactionCounters),
                             events: s.events.map(\.name), status: s.status, source: "device")
            }
        } else {
            dropped += 1
        }
        let outcome = TraceOutcome(traceID: trace.traceID, feature: trace.feature, decision: decision,
                                   rootDurationNanos: trace.rootDurationNanos, costPicoDollars: cost,
                                   spanCount: trace.spans.count, appliedOffsetNanos: offset,
                                   exported: exported, recorded: trace, bufferAccepted: false)
        return (outcome, decision.isKept ? (decision.isForced ? .forced : .sampled) : nil)
    }

    private func admit(_ o: TraceOutcome, priority: BufferPriority?) async -> TraceOutcome {
        var accepted = false
        if let priority {
            accepted = await buffer.enqueue(o.exported, priority: priority)
            if !accepted { refusedByBuffer += 1 }
        }
        // Note: concurrent `end` calls can reach the buffer in a different
        // order than their traces completed. Order across traces carries no
        // meaning for export; order within a trace is fixed before this point.
        let final = TraceOutcome(traceID: o.traceID, feature: o.feature, decision: o.decision,
                                 rootDurationNanos: o.rootDurationNanos, costPicoDollars: o.costPicoDollars,
                                 spanCount: o.spanCount, appliedOffsetNanos: o.appliedOffsetNanos,
                                 exported: o.exported, recorded: o.recorded, bufferAccepted: accepted)
        log.append(final)
        if log.count > configuration.decisionLogSize { log.removeFirst(log.count - configuration.decisionLogSize) }
        return final
    }

    /// Device wall time at the trace anchor, plus monotonic elapsed, plus offset.
    private func wall(_ mono: UInt64, _ t: CompletedTrace, _ offset: Int64) -> Int64 {
        let elapsed = Saturating.signed(Saturating.subtract(mono, t.anchorMono))
        return Saturating.add(Saturating.add(t.anchorWall, elapsed), offset)
    }
}
