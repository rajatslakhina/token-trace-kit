import Foundation

/// A replayable hybrid AI request, for the demo app and the end-to-end tests.
///
/// Everything runs in **virtual time** on a ``ManualClock``: no sleeping, no
/// network, no model. The tiers are simulated, but the tracing code they
/// drive is the real pipeline, and the "server" really parses the
/// `traceparent` header the client produced.
public struct LabScenario: Sendable, Hashable {
    public enum OnDevice: String, Sendable, Hashable, CaseIterable {
        /// The on-device model answers; no cloud call.
        case answers
        /// The device can't run the model (not eligible, model not downloaded).
        case unavailable
        /// The model declines the request (a guardrail refusal).
        case refuses
        /// The model answers, but the app's validator rejects it.
        case lowConfidence
    }

    public enum Cloud: String, Sendable, Hashable, CaseIterable {
        case healthy
        /// Slow vendor response, past the latency SLO.
        case slow
        /// First attempt gets 429, the retry succeeds.
        case rateLimitedOnce
        /// The proxy returns 500; the user sees an error.
        case fails
    }

    public var onDevice: OnDevice
    public var cloud: Cloud
    /// How far ahead of true (server) time this device's clock is. Negative = behind.
    public var deviceClockAheadMillis: Int64
    public var feature: String
    /// A careless debug attribute holding the prompt. Unclassified → dropped.
    public var leakPromptIntoDebugAttribute: Bool

    public init(onDevice: OnDevice = .refuses, cloud: Cloud = .healthy, deviceClockAheadMillis: Int64 = 2_400,
                feature: String = "note.summarize", leakPromptIntoDebugAttribute: Bool = true) {
        self.onDevice = onDevice
        self.cloud = cloud
        self.deviceClockAheadMillis = deviceClockAheadMillis
        self.feature = feature
        self.leakPromptIntoDebugAttribute = leakPromptIntoDebugAttribute
    }

    public var needsCloud: Bool { onDevice != .answers }
}

/// What one lab run produced.
public struct LabRun: Sendable {
    public let scenario: LabScenario
    public let outcome: TraceOutcome?
    /// Spans the simulated proxy and vendor exported (in server time), if
    /// the server kept the trace.
    public let serverSpans: [ExportedSpan]
    public let serverKept: Bool
    public let traceparentSent: [String]
    public let tracestateSent: [String?]
    /// Device + server spans, as the collector will hold them once flushed.
    public var merged: [ExportedSpan] {
        ((outcome?.exported ?? []) + serverSpans).sorted {
            ($0.startUnixNanos, $0.spanID.value) < ($1.startUnixNanos, $1.spanID.value)
        }
    }
    /// Spans that start before their parent or end after it: what a skewed
    /// device clock does to a waterfall.
    public var orderingViolations: Int { LabRun.violations(in: merged) }

    public static func violations(in spans: [ExportedSpan], toleranceNanos: Int64 = 1_000_000) -> Int {
        var byID: [SpanID: ExportedSpan] = [:]
        for s in spans { byID[s.spanID] = s }
        var n = 0
        for s in spans {
            guard let pid = s.parentID, let p = byID[pid] else { continue }
            if Saturating.add(s.startUnixNanos, toleranceNanos) < p.startUnixNanos
                || Saturating.subtract(s.endUnixNanos, toleranceNanos) > p.endUnixNanos { n += 1 }
        }
        return n
    }
}

/// An in-memory collector with a network switch.
public actor LabCollector: SpanExporter {
    public private(set) var online = true
    public private(set) var spans: [ExportedSpan] = []
    public private(set) var batchIDs: [String] = []
    public private(set) var duplicateBatches = 0
    public private(set) var attempts = 0
    /// Store the batch but "lose" the response, as a dropped connection
    /// after the server committed would. The client must retry the same id.
    public private(set) var losesAcks = false
    public private(set) var lastBatchID: String?

    public init() {}

    public func setOnline(_ v: Bool) { online = v }
    public func setLosesAcks(_ v: Bool) { losesAcks = v }

    public func export(_ batch: ExportBatch) async -> ExportResult {
        attempts += 1
        guard online else { return .retryable(retryAfterNanos: nil) }
        lastBatchID = batch.id
        // At-least-once in, exactly-once stored: dedupe by batch id.
        if batchIDs.contains(batch.id) {
            duplicateBatches += 1
            return .success
        }
        batchIDs.append(batch.id)
        if batchIDs.count > 1_000 { batchIDs.removeFirst(batchIDs.count - 1_000) }
        spans += batch.spans
        if spans.count > 5_000 { spans.removeFirst(spans.count - 5_000) }
        return losesAcks ? .retryable(retryAfterNanos: nil) : .success
    }

    public func ingestServerSpans(_ s: [ExportedSpan]) {
        spans += s
        if spans.count > 5_000 { spans.removeFirst(spans.count - 5_000) }
    }
}

/// Drives ``LabScenario`` runs through a real ``TracePipeline``.
public actor TraceLab {
    public nonisolated let pipeline: TracePipeline
    public nonisolated let collector = LabCollector()
    private let clock: ManualClock
    private let ids: SeededIDSource
    private let configuration: TracingConfiguration
    private var currentSkewMillis: Int64 = 0
    // Runs and flushes share one virtual clock, and `run` awaits the
    // pipeline actor, so two overlapping runs would interleave their clock
    // advances. A FIFO hand-off lock serializes them.
    /// Test seam: awaited at the start of every run, inside the lock.
    var runHook: (@Sendable () async -> Void)?
    func setRunHook(_ h: (@Sendable () async -> Void)?) { runHook = h }
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } // hand-off: busy stays true
    }

    public init(configuration: TracingConfiguration, seed: UInt64 = 42) {
        let clock = ManualClock()
        let ids = SeededIDSource(seed: seed)
        self.clock = clock
        self.ids = ids
        self.configuration = configuration
        // Deterministic jitter: half the ceiling.
        pipeline = TracePipeline(configuration: configuration, clock: clock, ids: ids, jitter: { $0 / 2 })
    }

    /// Server (true) time is device time minus the device's error.
    private func serverWall() -> Int64 {
        Saturating.subtract(clock.wallNanos, Saturating.multiply(currentSkewMillis, 1_000_000))
    }

    public func run(_ s: LabScenario) async -> LabRun {
        await acquire()
        defer { release() }
        await runHook?()
        // Apply the scenario's clock error relative to the previous run.
        let delta = Saturating.subtract(s.deviceClockAheadMillis, currentSkewMillis)
        clock.jumpWall(byNanos: Saturating.multiply(delta, 1_000_000))
        currentSkewMillis = s.deviceClockAheadMillis

        let p = pipeline
        let prompt = SensitiveText("Summarize: call Jane on +1 415 555 0100 about the Q3 renewal, card 4111 1111 1111 1111")
        let root = await p.startTrace("note.summarize.tap", attributes: [
            AttributeKey.feature: .string(s.feature),
            AttributeKey.userID: .string("user-8812"),
            AttributeKey.networkType: .string("wifi")
        ])
        await p.recordPrompt(prompt, on: root)
        if s.leakPromptIntoDebugAttribute {
            // What a well-meaning engineer adds while debugging. The policy
            // has no rule for this key, so it never leaves the device.
            await p.setAttribute("debug.prompt", .string("call Jane on +1 415 555 0100"), on: root)
        }
        clock.advance(millis: 12)

        // Tier 1: on-device model.
        let local = await p.startSpan("ai.ondevice.generate", parent: root, attributes: [
            AttributeKey.tier: .string("on-device"),
            AttributeKey.model: .string("apple.foundation-models")
        ])
        switch s.onDevice {
        case .answers:
            clock.advance(millis: 420)
            await p.end(local, status: .ok)
        case .unavailable:
            clock.advance(millis: 3)
            await p.end(local, status: .fallback(reason: "device-not-eligible"))
        case .refuses:
            clock.advance(millis: 260)
            await p.end(local, status: .refused)
        case .lowConfidence:
            clock.advance(millis: 510)
            await p.end(local, status: .fallback(reason: "validation-failed"))
        }

        var serverSpans: [ExportedSpan] = []
        var serverKept = false
        var parents: [String] = []
        var states: [String?] = []
        var rootStatus: SpanStatus = .ok

        if s.needsCloud {
            await p.setAttribute(AttributeKey.fallbackReason, .string(s.onDevice.rawValue), on: root)
            let attemptsNeeded = s.cloud == .rateLimitedOnce ? 2 : 1
            for attempt in 1...attemptsNeeded {
                let req = await p.startSpan("ai.cloud.request", kind: .client, parent: root, attributes: [
                    AttributeKey.tier: .string("cloud"),
                    AttributeKey.attempt: .int(Int64(attempt))
                ])
                let header = await p.traceparent(for: req)
                let state = await p.tracestate(for: req)
                parents.append(header)
                states.append(state)

                let sendMono = clock.monotonicNanos
                let sendWall = clock.wallNanos
                clock.advance(millis: 60) // uplink
                let serverReceive = serverWall()
                let response = simulateServer(header: header, tracestate: state, scenario: s,
                                              attempt: attempt, receivedAt: serverReceive)
                clock.advance(nanos: Saturating.unsigned(Saturating.subtract(response.sentAt, serverReceive)))
                clock.advance(millis: 60) // downlink
                await p.recordClockSample(ClockSample(clientSendWall: sendWall, clientSendMono: sendMono,
                                                      clientReceiveMono: clock.monotonicNanos,
                                                      serverReceiveWall: serverReceive,
                                                      serverSendWall: response.sentAt))
                if response.kept { serverSpans += response.spans; serverKept = true }
                await p.setAttribute(AttributeKey.httpStatus, .int(Int64(response.status)), on: req)
                switch response.status {
                case 200:
                    await p.setAttribute(AttributeKey.model, .string(LabPrices.cloudModel), on: req)
                    await p.setAttribute(AttributeKey.inputTokens, .int(response.inputTokens), on: req)
                    await p.setAttribute(AttributeKey.outputTokens, .int(response.outputTokens), on: req)
                    await p.setAttribute(AttributeKey.cacheReadTokens, .int(response.cacheReadTokens), on: req)
                    await p.end(req, status: .ok)
                case 429:
                    await p.addEvent("retry.scheduled", on: req)
                    await p.end(req, status: .error(code: "http.429"))
                    clock.advance(millis: 400) // client backoff
                default:
                    await p.setAttribute(AttributeKey.errorMessage,
                                         .string("upstream 500 for jane.doe@example.com, req \(attempt)"), on: req)
                    await p.end(req, status: .error(code: "http.\(response.status)"))
                    rootStatus = .error(code: "cloud.failed")
                }
            }
        }

        clock.advance(millis: 16) // render
        let outcome = await p.end(root, status: rootStatus)
        if !serverSpans.isEmpty { await collector.ingestServerSpans(serverSpans) }
        return LabRun(scenario: s, outcome: outcome, serverSpans: serverSpans, serverKept: serverKept,
                      traceparentSent: parents, tracestateSent: states)
    }

    public func setOnline(_ v: Bool) async { await collector.setOnline(v) }
    public func setLosesAcks(_ v: Bool) async { await collector.setLosesAcks(v) }

    /// Fast-forwards virtual time past any backoff, then flushes.
    public func flush() async -> FlushOutcome {
        await acquire()
        defer { release() }
        // Only as far as the pending retry needs, so clock-skew samples are
        // not aged out by repeated flushes.
        if let next = await pipeline.buffer.nextAttemptMonoNanos {
            clock.advance(nanos: Saturating.subtract(next, clock.monotonicNanos))
        }
        return await pipeline.flush(to: collector)
    }

    // MARK: - Simulated server (proxy + vendor), in server time

    struct ServerResponse {
        let status: Int
        let sentAt: Int64
        let spans: [ExportedSpan]
        let kept: Bool
        let inputTokens: Int64
        let outputTokens: Int64
        let cacheReadTokens: Int64
    }

    private func simulateServer(header: String, tracestate: String?, scenario s: LabScenario,
                                attempt: Int, receivedAt t: Int64) -> ServerResponse {
        let ms: (Int64) -> Int64 = { Saturating.multiply($0, 1_000_000) }
        // A server that can't parse the header starts its own trace: exactly
        // what happens in production when propagation is broken.
        let parent = TraceParent.parse(header)
        let traceID = parent?.traceID ?? ids.nextTraceID()
        let proxyID = ids.nextSpanID()
        let vendorID = ids.nextSpanID()

        let status: Int
        let vendorMillis: Int64
        switch (s.cloud, attempt) {
        case (.rateLimitedOnce, 1): status = 429; vendorMillis = 0
        case (.fails, _): status = 500; vendorMillis = 0
        case (.slow, _): status = 200; vendorMillis = 3_400
        default: status = 200; vendorMillis = 780
        }
        let (input, output, cache): (Int64, Int64, Int64) = status == 200 ? (1_850, 240, 1_200) : (0, 0, 0)

        var spans: [ExportedSpan] = []
        let proxyEnd: Int64
        if vendorMillis > 0 {
            let vStart = Saturating.add(t, ms(8))
            let vEnd = Saturating.add(vStart, ms(vendorMillis))
            proxyEnd = Saturating.add(vEnd, ms(6))
            spans.append(ExportedSpan(traceID: traceID, spanID: vendorID, parentID: proxyID, name: "claude.messages",
                                      kind: .server, startUnixNanos: vStart, endUnixNanos: vEnd,
                                      attributes: [AttributeKey.system: .string("anthropic"),
                                                   AttributeKey.model: .string(LabPrices.cloudModel),
                                                   AttributeKey.inputTokens: .int(input),
                                                   AttributeKey.outputTokens: .int(output),
                                                   AttributeKey.cacheReadTokens: .int(cache)],
                                      events: [], status: .ok, source: "vendor"))
        } else {
            proxyEnd = Saturating.add(t, ms(status == 429 ? 4 : 25))
        }
        let proxyStatus: SpanStatus = status == 200 ? .ok : .error(code: "http.\(status)")
        spans.insert(ExportedSpan(traceID: traceID, spanID: proxyID, parentID: parent?.parentID, name: "proxy.handle",
                                  kind: .server, startUnixNanos: t, endUnixNanos: proxyEnd,
                                  attributes: [AttributeKey.httpStatus: .int(Int64(status))],
                                  events: [], status: proxyStatus, source: "edge-proxy"), at: 0)

        // The server's own tail rule: notable, asked to keep, slow, or the
        // same consistent ratio the client uses.
        let notable = status != 200
        let slow = Saturating.subtract(proxyEnd, t) >= Saturating.signed(configuration.sampling.latencySLONanos)
        let kept = notable || slow || TraceStateKey.requestsKeep(tracestate) || configuration.sampling.ratioKeeps(traceID)
        return ServerResponse(status: status, sentAt: proxyEnd, spans: spans, kept: kept,
                              inputTokens: input, outputTokens: output, cacheReadTokens: cache)
    }
}

/// Illustrative prices for the lab. Not a pricing source: the app owns
/// its price table, and real prices belong in remote config.
public enum LabPrices {
    public static let cloudModel = "claude-haiku-5-5"
    public static let table = PriceTable([
        cloudModel: ModelPrice(inputMicrosPerMTok: 100_000, outputMicrosPerMTok: 500_000, cacheReadMicrosPerMTok: 10_000)
    ])
}
