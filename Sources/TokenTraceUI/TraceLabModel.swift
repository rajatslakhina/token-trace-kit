#if canImport(SwiftUI) && canImport(Observation)
import Foundation
import Observation
import TokenTrace

/// View model for ``TraceLabView``. All tracing work happens in the
/// ``TraceLab`` actor; this class only holds what the screen shows.
@MainActor
@Observable
public final class TraceLabModel {
    public var scenario: LabScenario
    public var showUncorrected = false
    public private(set) var lastRun: LabRun?
    public private(set) var runs = 0
    public private(set) var isBusy = false
    /// Bound directly by the view's toggles (key-path bindings, no closures).
    public var networkOnline = true {
        didSet {
            let v = networkOnline, lab = self.lab
            Task { await lab.setOnline(v) }
        }
    }
    public var collectorLosesAcks = false {
        didSet {
            let v = collectorLosesAcks, lab = self.lab
            Task { await lab.setLosesAcks(v) }
        }
    }
    /// The skew slider's value, as a Double for `Slider`.
    public var skewMillis: Double {
        get { Double(scenario.deviceClockAheadMillis) }
        set { scenario.deviceClockAheadMillis = Saturating.int64(newValue) }
    }
    public private(set) var lastFlush: String = "—"
    public private(set) var bufferedTraces = 0
    public private(set) var bufferedSpans = 0
    public private(set) var pendingRetry = false
    public private(set) var collectorSpans = 0
    public private(set) var duplicateBatches = 0
    public private(set) var lastBatchID: String?
    public private(set) var exportAttempts = 0
    public private(set) var costs: [FeatureCost] = []
    public private(set) var metrics: PipelineMetrics?

    private let lab: TraceLab

    public init(configuration: TracingConfiguration, scenario: LabScenario = LabScenario(), seed: UInt64 = 42) {
        lab = TraceLab(configuration: configuration, seed: seed)
        self.scenario = scenario
    }

    /// Waterfall rows: corrected (what the collector stores) or, for
    /// comparison, the device spans as they would look with no correction.
    public var displayedSpans: [ExportedSpan] {
        guard let run = lastRun else { return [] }
        guard showUncorrected, let o = run.outcome, o.appliedOffsetNanos != 0 else { return run.merged }
        let shifted = o.exported.map { s in
            ExportedSpan(traceID: s.traceID, spanID: s.spanID, parentID: s.parentID, name: s.name, kind: s.kind,
                         startUnixNanos: Saturating.subtract(s.startUnixNanos, o.appliedOffsetNanos),
                         endUnixNanos: Saturating.subtract(s.endUnixNanos, o.appliedOffsetNanos),
                         attributes: s.attributes, events: s.events, status: s.status, source: s.source)
        }
        return (shifted + run.serverSpans).sorted { $0.startUnixNanos < $1.startUnixNanos }
    }

    public var displayedViolations: Int { LabRun.violations(in: displayedSpans) }

    public func run() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastRun = await lab.run(scenario)
        runs += 1
        await refresh()
    }

    public func flush() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        switch await lab.flush() {
        case .nothingToSend: lastFlush = "nothing to send"
        case .alreadyFlushing: lastFlush = "already flushing"
        case .backingOff: lastFlush = "not acknowledged (offline or lost ack): batch kept for retry"
        case .exported(let b, let s): lastFlush = "sent \(s) spans in \(b) batch(es)"
        case .gaveUp(let id, _): lastFlush = "gave up on \(id) after max attempts"
        }
        await refresh()
    }

    private func refresh() async {
        let buffer = lab.pipeline.buffer
        bufferedTraces = await buffer.queuedTraces
        bufferedSpans = await buffer.usedSpans
        pendingRetry = await buffer.hasPendingRetry
        collectorSpans = await lab.collector.spans.count
        duplicateBatches = await lab.collector.duplicateBatches
        lastBatchID = await lab.collector.lastBatchID
        exportAttempts = await lab.collector.attempts
        costs = await lab.pipeline.costReport()
        metrics = await lab.pipeline.metrics()
    }
}
#endif
