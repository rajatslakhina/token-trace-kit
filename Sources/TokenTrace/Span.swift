/// What a caller holds for an in-flight span. Cheap, `Sendable`, and safe to
/// use after the span has ended (every operation on an ended span is a no-op).
public struct SpanHandle: Hashable, Sendable {
    public let traceID: TraceID
    public let spanID: SpanID
    /// False when a limit was hit and this span is not being recorded. It can
    /// still be propagated, so downstream tiers keep a consistent trace-id.
    public let isRecording: Bool
}

public struct SpanEvent: Hashable, Sendable, Codable {
    public let name: String
    public let atMono: UInt64
}

/// A span as recorded on this device, in monotonic time.
public struct FinishedSpan: Hashable, Sendable {
    public let spanID: SpanID
    public let parentID: SpanID?
    public let name: String
    public let kind: SpanKind
    public let startMono: UInt64
    public let endMono: UInt64
    public let attributes: [String: AttributeValue]
    public let events: [SpanEvent]
    public let status: SpanStatus

    public var durationNanos: UInt64 { Saturating.subtract(endMono, startMono) }
}

public enum CompletionReason: String, Sendable, Codable {
    /// The root and every child ended.
    case finished
    /// The trace hit its timeout; open spans were force-ended as `.abandoned`.
    case timedOut
}

/// A trace whose spans have all ended. Input to sampling, cost and export.
public struct CompletedTrace: Sendable {
    public let traceID: TraceID
    public let rootSpanID: SpanID
    /// The remote span this trace continues, if it started from a `traceparent`.
    public let remoteParentID: SpanID?
    /// Device wall time and monotonic time read together when the root started.
    public let anchorWall: Int64
    public let anchorMono: UInt64
    /// Sorted by start time, then span id, so output is deterministic.
    public let spans: [FinishedSpan]
    public let droppedSpans: Int
    public let reason: CompletionReason

    public var root: FinishedSpan? { spans.first { $0.spanID == rootSpanID } }
    public var rootDurationNanos: UInt64 { root?.durationNanos ?? 0 }
    public var feature: String { root?.attributes[AttributeKey.feature]?.stringValue ?? "unknown" }
}

/// Span on the wire: wall-clock timestamps, already redacted and time-corrected.
public struct ExportedSpan: Hashable, Sendable, Codable {
    public let traceID: TraceID
    public let spanID: SpanID
    public let parentID: SpanID?
    public let name: String
    public let kind: SpanKind
    public let startUnixNanos: Int64
    public let endUnixNanos: Int64
    public let attributes: [String: AttributeValue]
    public let events: [String]
    public let status: SpanStatus
    /// Who produced it ("device", or a server/vendor name in a collector view).
    public let source: String

    public init(traceID: TraceID, spanID: SpanID, parentID: SpanID?, name: String, kind: SpanKind,
                startUnixNanos: Int64, endUnixNanos: Int64, attributes: [String: AttributeValue],
                events: [String], status: SpanStatus, source: String) {
        self.traceID = traceID
        self.spanID = spanID
        self.parentID = parentID
        self.name = name
        self.kind = kind
        self.startUnixNanos = startUnixNanos
        self.endUnixNanos = max(startUnixNanos, endUnixNanos)
        self.attributes = attributes
        self.events = events
        self.status = status
        self.source = source
    }

    var estimatedBytes: Int {
        64 + name.utf8.count + attributes.reduce(0) { $0 + $1.key.utf8.count + $1.value.estimatedBytes }
            + events.reduce(0) { $0 + $1.utf8.count }
    }
}
