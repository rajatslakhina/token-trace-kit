/// A batch of spans sent in one request. Its id is fixed when the batch is
/// formed and reused on every retry, so a collector can drop duplicates:
/// delivery is at-least-once, de-duplicated by `id`.
public struct ExportBatch: Sendable, Hashable, Codable {
    public let id: String
    public let spans: [ExportedSpan]
    public let attempt: Int
}

public enum ExportResult: Sendable, Hashable {
    case success
    /// Transient (offline, 5xx, 429). `retryAfterNanos` is the server's hint.
    case retryable(retryAfterNanos: UInt64?)
    /// Permanent (400, 413). Retrying cannot help, so the batch is dropped.
    case rejected
}

public protocol SpanExporter: Sendable {
    func export(_ batch: ExportBatch) async -> ExportResult
}

public enum BufferPriority: Int, Sendable, Hashable, Codable, Comparable {
    /// A ratio-sampled healthy trace: first to go under pressure.
    case sampled = 0
    /// An error, refusal, fallback, timeout or slow trace.
    case forced = 1
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct BufferLimits: Sendable, Hashable {
    public var maxSpans: Int
    public var maxBytes: Int
    public var maxBatchSpans: Int
    public var maxAttempts: Int
    public var baseBackoffNanos: UInt64
    public var maxBackoffNanos: UInt64

    public init(maxSpans: Int = 2_000, maxBytes: Int = 512 * 1024, maxBatchSpans: Int = 200, maxAttempts: Int = 6,
                baseBackoffNanos: UInt64 = 1_000_000_000, maxBackoffNanos: UInt64 = 300_000_000_000) {
        self.maxSpans = min(max(1, maxSpans), 1_000_000)
        self.maxBytes = min(max(1, maxBytes), 256 * 1024 * 1024)
        self.maxBatchSpans = min(max(1, maxBatchSpans), 100_000)
        self.maxAttempts = max(1, maxAttempts)
        self.baseBackoffNanos = max(1, baseBackoffNanos)
        self.maxBackoffNanos = max(self.baseBackoffNanos, maxBackoffNanos)
    }
}

public struct BufferCounters: Sendable, Hashable, Codable {
    public var acceptedTraces = 0
    public var evictedSampledTraces = 0
    public var evictedForcedTraces = 0
    public var refusedTraces = 0
    public var exportedBatches = 0
    public var exportedSpans = 0
    public var retries = 0
    public var droppedAfterRetries = 0
    public var rejectedBatches = 0
    /// A restored in-flight batch that no longer fits the current limits.
    public var droppedOnRestore = 0
}

public enum FlushOutcome: Sendable, Hashable {
    case nothingToSend
    case alreadyFlushing
    case backingOff(untilMono: UInt64)
    case exported(batches: Int, spans: Int)
    /// A batch hit `maxAttempts` and was dropped. The flush stops there
    /// rather than sending the next batch to an endpoint that just failed.
    case gaveUp(batchID: String, exportedBefore: Int)
}

/// Codable snapshot so the app can persist the buffer when it is backgrounded.
public struct BufferSnapshot: Sendable, Codable, Hashable {
    public struct Entry: Sendable, Codable, Hashable {
        public let spans: [ExportedSpan]
        public let priority: BufferPriority
    }
    public let entries: [Entry]
    public let pendingRetry: ExportBatch?
    public let nextSequence: UInt64
}

/// Bounded offline buffer between the sampler and the network.
///
/// **Units.** Admission and eviction work on whole traces, never single spans:
/// half a trace is worse than none, because it renders as a broken waterfall
/// that looks like a bug in the app.
///
/// **Pressure.** When full, the oldest *sampled* trace goes first. A forced
/// trace (an error, a refusal) is only evicted to make room for a newer forced
/// trace, and a sampled trace never displaces a forced one.
///
/// **Reentrancy.** `flush` awaits the exporter, and actors are reentrant, so a
/// second `flush` could start mid-request. It returns `.alreadyFlushing`
/// instead. The batch being sent is held outside the queue, so eviction
/// running during the await can never touch it, and on a retryable failure
/// it is retried later as the same batch with the same id.
public actor ExportBuffer {
    struct Entry: Sendable {
        let spans: [ExportedSpan]
        let priority: BufferPriority
        let bytes: Int
    }

    public nonisolated let limits: BufferLimits
    private let installID: String
    private let clock: TraceClock
    private let jitter: @Sendable (UInt64) -> UInt64
    private var queue: [Entry] = []
    private var retryBatch: ExportBatch?
    private var retryBatchBytes = 0
    private var nextAttemptMono: UInt64 = 0
    private var flushing = false
    private var sequence: UInt64 = 0
    public private(set) var counters = BufferCounters()

    /// - Parameters:
    ///   - installID: a stable per-install id, so batch ids never collide
    ///     across devices or reinstalls.
    ///   - jitter: maps a backoff ceiling to the actual delay. Defaults to
    ///     "full jitter" (uniform in 0...ceiling), which spreads a fleet of
    ///     phones coming back online at once.
    public init(limits: BufferLimits = BufferLimits(), installID: String, clock: TraceClock,
                restoring snapshot: BufferSnapshot? = nil,
                jitter: @escaping @Sendable (UInt64) -> UInt64 = { UInt64.random(in: 0...$0) }) {
        self.limits = limits
        self.installID = installID
        self.clock = clock
        self.jitter = jitter
        if let snapshot {
            sequence = snapshot.nextSequence
            retryBatch = snapshot.pendingRetry
            var heldBytes = snapshot.pendingRetry.map { $0.spans.reduce(0) { $0 + $1.estimatedBytes } } ?? 0
            var c = BufferCounters()
            if let r = snapshot.pendingRetry, r.spans.count > limits.maxSpans || heldBytes > limits.maxBytes {
                // A snapshot from a build with larger limits: the held batch
                // alone breaks the budget, so it cannot be kept.
                retryBatch = nil
                heldBytes = 0
                c.droppedOnRestore += 1
            }
            retryBatchBytes = heldBytes
            var q = snapshot.entries.map { Entry(spans: $0.spans, priority: $0.priority,
                                                 bytes: $0.spans.reduce(0) { $0 + $1.estimatedBytes }) }
            // A snapshot can come from an older build with larger limits.
            let held = retryBatch?.spans.count ?? 0
            while held + q.reduce(0, { $0 + $1.spans.count }) > limits.maxSpans
                    || heldBytes + q.reduce(0, { $0 + $1.bytes }) > limits.maxBytes,
                  let evicted = Self.evict(from: &q, for: .forced) {
                if evicted == .sampled { c.evictedSampledTraces += 1 } else { c.evictedForcedTraces += 1 }
            }
            queue = q
            counters = c
        }
    }

    public var usedSpans: Int { queue.reduce(retryBatch?.spans.count ?? 0) { $0 + $1.spans.count } }
    public var usedBytes: Int { queue.reduce(retryBatchBytes) { $0 + $1.bytes } }
    public var queuedTraces: Int { queue.count }
    public var hasPendingRetry: Bool { retryBatch != nil }
    /// When the pending retry may be sent, or nil if nothing is waiting.
    public var nextAttemptMonoNanos: UInt64? { retryBatch == nil ? nil : nextAttemptMono }

    /// Admits one trace's spans. Returns false if it was refused.
    @discardableResult
    public func enqueue(_ spans: [ExportedSpan], priority: BufferPriority) -> Bool {
        guard !spans.isEmpty else { return false }
        let entry = Entry(spans: spans, priority: priority, bytes: spans.reduce(0) { $0 + $1.estimatedBytes })
        guard entry.spans.count <= limits.maxSpans, entry.bytes <= limits.maxBytes else {
            counters.refusedTraces += 1
            return false
        }
        while usedSpans + entry.spans.count > limits.maxSpans || usedBytes + entry.bytes > limits.maxBytes {
            guard evictOne(for: priority) else {
                counters.refusedTraces += 1
                return false
            }
        }
        queue.append(entry)
        counters.acceptedTraces += 1
        return true
    }

    /// Sends what it can. Stops at the first failure; never sends while
    /// backing off. Safe to call from a reachability callback, a timer and
    /// `sceneDidEnterBackground` at the same time.
    public func flush(to exporter: SpanExporter) async -> FlushOutcome {
        guard !flushing else { return .alreadyFlushing }
        let now = clock.monotonicNanos
        if retryBatch != nil && now < nextAttemptMono { return .backingOff(untilMono: nextAttemptMono) }
        guard retryBatch != nil || !queue.isEmpty else { return .nothingToSend }
        flushing = true
        defer { flushing = false }

        var batches = 0
        var spans = 0
        while let batch = takeNextBatch() {
            let result = await exporter.export(batch)
            // Back on the actor: queue may have changed, `batch` has not.
            switch result {
            case .success:
                clearRetry()
                batches += 1
                spans += batch.spans.count
                counters.exportedBatches += 1
                counters.exportedSpans += batch.spans.count
            case .rejected:
                clearRetry()
                counters.rejectedBatches += 1
            case .retryable(let hint):
                let attempt = min(max(batch.attempt, 0), limits.maxAttempts) + 1
                guard attempt < limits.maxAttempts else {
                    clearRetry()
                    counters.droppedAfterRetries += 1
                    return .gaveUp(batchID: batch.id, exportedBefore: batches)
                }
                counters.retries += 1
                retryBatch = ExportBatch(id: batch.id, spans: batch.spans, attempt: attempt)
                retryBatchBytes = batch.spans.reduce(0) { $0 + $1.estimatedBytes }
                let delay = max(hint ?? 0, jitter(backoffCeiling(attempt: attempt)))
                nextAttemptMono = Saturating.add(clock.monotonicNanos, min(delay, limits.maxBackoffNanos))
                return batches > 0 ? .exported(batches: batches, spans: spans)
                                   : .backingOff(untilMono: nextAttemptMono)
            }
        }
        return batches > 0 ? .exported(batches: batches, spans: spans) : .nothingToSend
    }

    public func snapshot() -> BufferSnapshot {
        BufferSnapshot(entries: queue.map { .init(spans: $0.spans, priority: $0.priority) },
                       pendingRetry: retryBatch, nextSequence: sequence)
    }

    /// Exponential ceiling: base × 2^(attempt−1), capped. Exposed for tests.
    public func backoffCeiling(attempt: Int) -> UInt64 {
        let shift = attempt <= 1 ? 0 : min(attempt - 1, 62)
        return min(limits.maxBackoffNanos, Saturating.multiply(limits.baseBackoffNanos, UInt64(1) << UInt64(shift)))
    }

    // MARK: - Private

    /// The retry batch first (same id, same spans), otherwise a new batch of
    /// whole traces from the front of the queue.
    private func takeNextBatch() -> ExportBatch? {
        if let r = retryBatch { return r }
        guard !queue.isEmpty else { return nil }
        var spans: [ExportedSpan] = []
        var bytes = 0
        // Always take at least one trace, so a trace larger than a batch still ships.
        while let first = queue.first, spans.isEmpty || spans.count + first.spans.count <= limits.maxBatchSpans {
            spans += first.spans
            bytes += first.bytes
            queue.removeFirst()
        }
        sequence = Saturating.add(sequence, 1)
        let batch = ExportBatch(id: "\(installID)-\(sequence)", spans: spans, attempt: 0)
        // Held here while in flight, so it still counts against the limits.
        retryBatch = batch
        retryBatchBytes = bytes
        return batch
    }

    private func clearRetry() {
        retryBatch = nil
        retryBatchBytes = 0
        nextAttemptMono = 0
    }

    private func evictOne(for priority: BufferPriority) -> Bool {
        guard let evicted = Self.evict(from: &queue, for: priority) else { return false }
        if evicted == .sampled { counters.evictedSampledTraces += 1 } else { counters.evictedForcedTraces += 1 }
        return true
    }

    /// Removes the oldest entry an incoming trace of `priority` may displace
    /// and returns its priority, or nil if nothing may be displaced.
    static func evict(from queue: inout [Entry], for priority: BufferPriority) -> BufferPriority? {
        if let i = queue.firstIndex(where: { $0.priority == .sampled }) {
            queue.remove(at: i)
            return .sampled
        }
        if priority == .forced, let i = queue.firstIndex(where: { $0.priority == .forced }) {
            queue.remove(at: i)
            return .forced
        }
        return nil
    }
}
