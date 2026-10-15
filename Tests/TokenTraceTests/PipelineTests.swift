import XCTest
@testable import TokenTrace

// MARK: - Helpers

func span(_ trace: UInt64, _ id: UInt64, bytesOfName: Int = 4) -> ExportedSpan {
    // Tests pass non-zero literals; `max(1, …)` makes that hold regardless.
    ExportedSpan(traceID: TraceID(high: 0, low: max(1, trace))!, spanID: SpanID(max(1, id))!, parentID: nil,
                 name: String(repeating: "n", count: bytesOfName), kind: .internal,
                 startUnixNanos: 0, endUnixNanos: 1, attributes: [:], events: [], status: .ok, source: "device")
}

func traceSpans(_ trace: UInt64, count: Int) -> [ExportedSpan] {
    (1...max(1, count)).map { span(trace, trace * 1_000 + UInt64($0)) }
}

actor RecordingExporter: SpanExporter {
    var results: [ExportResult]
    var batches: [ExportBatch] = []
    init(_ results: [ExportResult] = []) { self.results = results }
    func export(_ batch: ExportBatch) async -> ExportResult {
        batches.append(batch)
        return results.isEmpty ? .success : results.removeFirst()
    }
}

/// An exporter that parks inside `export` until released, to create a real
/// overlap between a flush in flight and other calls on the buffer.
actor GateExporter: SpanExporter {
    private var waiting: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var hasEntered = false
    var batches: [ExportBatch] = []

    func export(_ batch: ExportBatch) async -> ExportResult {
        batches.append(batch)
        hasEntered = true
        entered?.resume()
        entered = nil
        await withCheckedContinuation { waiting = $0 }
        return .success
    }

    func waitUntilEntered() async {
        if hasEntered { return }
        await withCheckedContinuation { entered = $0 }
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}

/// Counts entries into `TraceLab.run` and parks them until released.
actor RunProbe {
    private(set) var entries = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var released = false

    func enter() async {
        entries += 1
        for (i, w) in entryWaiters.enumerated().reversed() where entries >= w.0 {
            entryWaiters.remove(at: i)
            w.1.resume()
        }
        if released { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func waitForEntries(_ n: Int) async {
        if entries >= n { return }
        await withCheckedContinuation { entryWaiters.append((n, $0)) }
    }

    func releaseAll() {
        released = true
        for p in parked { p.resume() }
        parked.removeAll()
    }
}

// MARK: - Export buffer

final class ExportBufferTests: XCTestCase {
    func makeBuffer(_ limits: BufferLimits = BufferLimits(), clock: ManualClock = ManualClock()) -> ExportBuffer {
        ExportBuffer(limits: limits, installID: "inst", clock: clock, jitter: { $0 })
    }

    func testBatchesAreWholeTracesAndAnOversizeTraceStillShips() async {
        let b = makeBuffer(BufferLimits(maxBatchSpans: 5))
        await b.enqueue(traceSpans(1, count: 3), priority: .sampled)
        await b.enqueue(traceSpans(2, count: 3), priority: .sampled)
        await b.enqueue(traceSpans(3, count: 8), priority: .forced)
        let e = RecordingExporter()
        let outcome = await b.flush(to: e)
        XCTAssertEqual(outcome, .exported(batches: 3, spans: 14))
        let sizes = await e.batches.map(\.spans.count)
        XCTAssertEqual(sizes, [3, 3, 8])
        let ids = await e.batches.map(\.id)
        XCTAssertEqual(ids, ["inst-1", "inst-2", "inst-3"])
    }

    func testPressureEvictsSampledFirstAndNeverLetsSampledDisplaceForced() async {
        let b = makeBuffer(BufferLimits(maxSpans: 6))
        await b.enqueue(traceSpans(1, count: 2), priority: .forced)
        await b.enqueue(traceSpans(2, count: 2), priority: .sampled)
        await b.enqueue(traceSpans(3, count: 2), priority: .forced)
        // Full. A forced trace evicts the sampled one.
        let a1 = await b.enqueue(traceSpans(4, count: 2), priority: .forced)
        XCTAssertTrue(a1)
        // Only forced remain: a sampled trace is refused rather than displacing one.
        let a2 = await b.enqueue(traceSpans(5, count: 2), priority: .sampled)
        XCTAssertFalse(a2)
        // A newer forced trace displaces the oldest forced one.
        let a3 = await b.enqueue(traceSpans(6, count: 2), priority: .forced)
        XCTAssertTrue(a3)
        let c = await b.counters
        XCTAssertEqual(c.evictedSampledTraces, 1)
        XCTAssertEqual(c.evictedForcedTraces, 1)
        XCTAssertEqual(c.refusedTraces, 1)
        let e = RecordingExporter()
        _ = await b.flush(to: e)
        let traces = await e.batches.flatMap(\.spans).map(\.traceID.low)
        XCTAssertEqual(Set(traces), [3, 4, 6])
    }

    func testByteLimitAndOversizeTraceAreEnforced() async {
        let b = makeBuffer(BufferLimits(maxBytes: 300))
        let big = [span(1, 1, bytesOfName: 400)]
        let refused = await b.enqueue(big, priority: .forced)
        XCTAssertFalse(refused)
        let empty = await b.enqueue([], priority: .forced)
        XCTAssertFalse(empty)
        for t in 2...10 { await b.enqueue([span(UInt64(t), UInt64(t))], priority: .sampled) }
        let used = await b.usedBytes
        XCTAssertLessThanOrEqual(used, 300)
    }

    func testRetryReusesTheSameBatchIDAndContentThenGivesUp() async {
        let clock = ManualClock()
        let b = makeBuffer(BufferLimits(maxAttempts: 3, baseBackoffNanos: 1_000, maxBackoffNanos: 100_000), clock: clock)
        await b.enqueue(traceSpans(1, count: 2), priority: .forced)
        let e = RecordingExporter([.retryable(retryAfterNanos: nil), .retryable(retryAfterNanos: nil), .retryable(retryAfterNanos: nil)])
        let r1 = await b.flush(to: e)
        XCTAssertEqual(r1, .backingOff(untilMono: clock.monotonicNanos + 1_000))
        // While backing off nothing is sent.
        let r2 = await b.flush(to: e)
        XCTAssertEqual(r2, .backingOff(untilMono: clock.monotonicNanos + 1_000))
        let sentSoFar = await e.batches.count
        XCTAssertEqual(sentSoFar, 1)
        clock.advance(nanos: 1_000)
        _ = await b.flush(to: e)          // attempt 2, backoff 2_000
        clock.advance(nanos: 2_000)
        let last = await b.flush(to: e)   // attempt 3 → max reached, dropped
        XCTAssertEqual(last, .gaveUp(batchID: "inst-1", exportedBefore: 0))
        let batches = await e.batches
        XCTAssertEqual(batches.map(\.id), ["inst-1", "inst-1", "inst-1"])
        XCTAssertEqual(batches.map(\.attempt), [0, 1, 2])
        XCTAssertEqual(Set(batches.map(\.spans)).count, 1)
        let c = await b.counters
        XCTAssertEqual(c.droppedAfterRetries, 1)
        let pending = await b.hasPendingRetry
        XCTAssertFalse(pending)
    }

    func testCorruptAttemptCountsAndAttemptArgumentsDoNotTrap() async throws {
        let clock = ManualClock()
        let b = makeBuffer(BufferLimits(maxAttempts: 3), clock: clock)
        let c0 = await b.backoffCeiling(attempt: .min)
        XCTAssertEqual(c0, 1_000_000_000)
        let cMax = await b.backoffCeiling(attempt: .max)
        XCTAssertEqual(cMax, 300_000_000_000)
        // A snapshot whose retry batch claims Int.max attempts.
        let snap = BufferSnapshot(entries: [], pendingRetry: ExportBatch(id: "x-1", spans: traceSpans(1, count: 1), attempt: .max),
                                  nextSequence: 1)
        let restored = ExportBuffer(limits: BufferLimits(maxAttempts: 3), installID: "x", clock: clock, restoring: snap)
        let r = await restored.flush(to: RecordingExporter([.retryable(retryAfterNanos: nil)]))
        XCTAssertEqual(r, .gaveUp(batchID: "x-1", exportedBefore: 0))
    }

    func testRetryAfterHintIsAFloorAndBackoffIsCapped() async {
        let clock = ManualClock()
        let b = makeBuffer(BufferLimits(baseBackoffNanos: 1_000, maxBackoffNanos: 50_000), clock: clock)
        let ceilings = await [1, 2, 3, 10, 200].asyncMap { await b.backoffCeiling(attempt: $0) }
        XCTAssertEqual(ceilings, [1_000, 2_000, 4_000, 50_000, 50_000])
        await b.enqueue(traceSpans(1, count: 1), priority: .forced)
        let e = RecordingExporter([.retryable(retryAfterNanos: 30_000)])
        let r = await b.flush(to: e)
        XCTAssertEqual(r, .backingOff(untilMono: clock.monotonicNanos + 30_000))
        let e2 = RecordingExporter([.retryable(retryAfterNanos: 9_999_999)])
        clock.advance(nanos: 30_000)
        let r2 = await b.flush(to: e2)
        XCTAssertEqual(r2, .backingOff(untilMono: clock.monotonicNanos + 50_000), "hint is capped too")
    }

    func testGivingUpStopsTheFlushInsteadOfHammeringTheEndpoint() async {
        let b = makeBuffer(BufferLimits(maxBatchSpans: 1, maxAttempts: 1))
        await b.enqueue(traceSpans(1, count: 1), priority: .forced)
        await b.enqueue(traceSpans(2, count: 1), priority: .forced)
        let e = RecordingExporter([.retryable(retryAfterNanos: nil), .success])
        let r = await b.flush(to: e)
        XCTAssertEqual(r, .gaveUp(batchID: "inst-1", exportedBefore: 0))
        let sent = await e.batches.count
        XCTAssertEqual(sent, 1, "the second batch waits for the next flush")
        let next = await b.flush(to: e)
        XCTAssertEqual(next, .exported(batches: 1, spans: 1))
    }

    func testRestoringAnInFlightBatchLargerThanTheNewLimitsDropsIt() async {
        let clock = ManualClock()
        let b = makeBuffer(BufferLimits(), clock: clock)
        await b.enqueue(traceSpans(1, count: 5), priority: .forced)
        _ = await b.flush(to: RecordingExporter([.retryable(retryAfterNanos: nil)]))
        let snap = await b.snapshot()
        XCTAssertNotNil(snap.pendingRetry)
        let small = ExportBuffer(limits: BufferLimits(maxSpans: 3), installID: "inst", clock: clock, restoring: snap)
        let used = await small.usedSpans
        XCTAssertEqual(used, 0)
        let c = await small.counters
        XCTAssertEqual(c.droppedOnRestore, 1)
    }

    func testRejectedBatchIsDroppedAndTheNextOneStillGoes() async {
        let b = makeBuffer(BufferLimits(maxBatchSpans: 1))
        await b.enqueue(traceSpans(1, count: 1), priority: .forced)
        await b.enqueue(traceSpans(2, count: 1), priority: .forced)
        let e = RecordingExporter([.rejected, .success])
        let r = await b.flush(to: e)
        XCTAssertEqual(r, .exported(batches: 1, spans: 1))
        let c = await b.counters
        XCTAssertEqual(c.rejectedBatches, 1)
    }

    func testConcurrentFlushIsRefusedAndTheInFlightBatchIsUntouchedByNewWork() async {
        let b = makeBuffer(BufferLimits(maxSpans: 4))
        await b.enqueue(traceSpans(1, count: 2), priority: .sampled)
        let gate = GateExporter()
        let first = Task { await b.flush(to: gate) }
        await gate.waitUntilEntered()
        // The flush is suspended inside the exporter. A second flush must not start.
        let second = await b.flush(to: RecordingExporter())
        XCTAssertEqual(second, .alreadyFlushing)
        // New traces arrive mid-flight and pressure the buffer. The in-flight
        // (sampled) batch still counts against the limit and cannot be evicted.
        let accepted = await b.enqueue(traceSpans(2, count: 2), priority: .forced)
        XCTAssertTrue(accepted)
        let overflow = await b.enqueue(traceSpans(3, count: 2), priority: .sampled)
        XCTAssertFalse(overflow)
        await gate.release()
        // The first flush continues with the trace enqueued meanwhile; release that too.
        let firstBatch = await gate.batches.first
        XCTAssertEqual(firstBatch?.spans.map(\.traceID.low), [1, 1])
        while await gate.batches.count < 2 { await Task.yield() }
        await gate.release()
        let outcome = await first.value
        XCTAssertEqual(outcome, .exported(batches: 2, spans: 4))
    }

    func testSnapshotRestorePreservesTheRetryBatchAndNeverReusesAnID() async throws {
        let clock = ManualClock()
        let b = makeBuffer(BufferLimits(maxBatchSpans: 1), clock: clock)
        await b.enqueue(traceSpans(1, count: 1), priority: .forced)
        await b.enqueue(traceSpans(2, count: 1), priority: .sampled)
        _ = await b.flush(to: RecordingExporter([.retryable(retryAfterNanos: nil)]))
        let snap = await b.snapshot()
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(BufferSnapshot.self, from: data)

        let restored = ExportBuffer(limits: BufferLimits(maxBatchSpans: 1), installID: "inst", clock: clock,
                                    restoring: decoded, jitter: { $0 })
        let e = RecordingExporter()
        _ = await restored.flush(to: e)
        let ids = await e.batches.map(\.id)
        XCTAssertEqual(ids, ["inst-1", "inst-2"], "retry batch keeps its id; the next id continues the sequence")
    }

    func testRestoringIntoSmallerLimitsEvictsSampledFirst() async throws {
        let b = makeBuffer()
        await b.enqueue(traceSpans(1, count: 3), priority: .forced)
        await b.enqueue(traceSpans(2, count: 3), priority: .sampled)
        let snap = await b.snapshot()
        let small = ExportBuffer(limits: BufferLimits(maxSpans: 4), installID: "inst", clock: ManualClock(), restoring: snap)
        let used = await small.usedSpans
        XCTAssertEqual(used, 3)
        let c = await small.counters
        XCTAssertEqual(c.evictedSampledTraces, 1)
    }
}

extension Array {
    func asyncMap<T>(_ f: (Element) async -> T) async -> [T] {
        var out: [T] = []
        for x in self { out.append(await f(x)) }
        return out
    }
}

// MARK: - Pipeline

final class TracePipelineTests: XCTestCase {
    func config(ratio: Double = 0, skew: Bool = true, limits: TraceLimits = TraceLimits()) -> TracingConfiguration {
        TracingConfiguration(limits: limits, sampling: SamplingPolicy(latencySLONanos: 2_500_000_000, healthyKeepRatio: ratio),
                             prices: LabPrices.table, hashKey: Array("k".utf8), installID: "test",
                             applySkewCorrection: skew)
    }

    func testTraceparentIdentifiesTheSpanAndTracestateFlagsAnAlreadyNotableTrace() async throws {
        let p = TracePipeline(configuration: config(), clock: ManualClock(), ids: SeededIDSource(seed: 3))
        let root = await p.startTrace("tap")
        let local = await p.startSpan("local", parent: root)
        let req1 = await p.startSpan("req", kind: .client, parent: root)
        let header1 = await p.traceparent(for: req1)
        let parsed = try XCTUnwrap(TraceParent.parse(header1))
        XCTAssertEqual(parsed.traceID, root.traceID)
        XCTAssertEqual(parsed.parentID, req1.spanID)
        XCTAssertEqual(parsed.flags, [.sampled, .random])
        let healthyState = await p.tracestate(for: req1)
        XCTAssertNil(healthyState)
        await p.end(local, status: .refused)
        let state = await p.tracestate(for: req1)
        XCTAssertEqual(state, "tokentrace=k")
        XCTAssertTrue(TraceStateKey.requestsKeep("other=1, tokentrace=k"))
        XCTAssertFalse(TraceStateKey.requestsKeep("tokentrace=x"))
    }

    func testContinuingARemoteHeaderJoinsItsTraceAndAnInvalidOneStartsFresh() async throws {
        let p = TracePipeline(configuration: config(ratio: 1), clock: ManualClock(), ids: SeededIDSource(seed: 4))
        let header = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        let joined = await p.startTrace("push.open", continuing: header)
        XCTAssertEqual(joined.traceID.hex, "4bf92f3577b34da6a3ce929d0e0e4736")
        let ended = await p.end(joined)
        let o = try XCTUnwrap(ended)
        XCTAssertEqual(o.exported.first?.parentID?.hex, "00f067aa0ba902b7")

        let fresh = await p.startTrace("push.open", continuing: "garbage")
        XCTAssertNotEqual(fresh.traceID.hex, "4bf92f3577b34da6a3ce929d0e0e4736")
        XCTAssertTrue(fresh.isRecording)
    }

    func testCostCountsDroppedTracesSoSamplingNeverChangesTheBill() async throws {
        let clock = ManualClock()
        let p = TracePipeline(configuration: config(ratio: 0), clock: clock, ids: SeededIDSource(seed: 5))
        for _ in 0..<10 {
            let r = await p.startTrace("tap", attributes: [AttributeKey.feature: .string("f")])
            let c = await p.startSpan("call", kind: .client, parent: r, attributes: [
                AttributeKey.model: .string(LabPrices.cloudModel),
                AttributeKey.inputTokens: .int(1_000), AttributeKey.outputTokens: .int(100)])
            clock.advance(millis: 50)
            await p.end(c)
            await p.end(r)
        }
        let m = await p.metrics()
        XCTAssertEqual(m.tracesDropped, 10, "ratio 0 and nothing notable: every trace is dropped")
        let report = await p.costReport()
        let f = try XCTUnwrap(report.first)
        XCTAssertEqual(f.traces, 10)
        XCTAssertEqual(f.picoDollars, 10 * (1_000 * 100_000 + 100 * 500_000))
    }

    /// The review's blocker: a wall-clock change between the clock sample and
    /// the trace must not leave a stale offset behind.
    func testWallClockChangeBetweenSampleAndTraceDoesNotCorruptExportedTime() async throws {
        let clock = ManualClock()
        let p = TracePipeline(configuration: config(ratio: 1), clock: clock, ids: SeededIDSource(seed: 9))
        // Device is 2 s ahead of the server when the sample is taken.
        let sendMono = clock.monotonicNanos, sendWall = clock.wallNanos
        let serverRecv = sendWall - 2_000_000_000 + 50_000_000
        clock.advance(millis: 100)
        await p.recordClockSample(ClockSample(clientSendWall: sendWall, clientSendMono: sendMono,
                                              clientReceiveMono: clock.monotonicNanos,
                                              serverReceiveWall: serverRecv, serverSendWall: serverRecv))
        // NTP then fixes the device clock: it is now 2 s earlier.
        clock.jumpWall(byNanos: -2_000_000_000)
        let trueNow = clock.wallNanos // device is now correct, so this is server time
        let r = await p.startTrace("tap")
        let ended = await p.end(r)
        let o = try XCTUnwrap(ended)
        XCTAssertEqual(o.appliedOffsetNanos, 0, "nothing left to correct after the device clock was fixed")
        XCTAssertEqual(o.exported.first?.startUnixNanos, trueNow)
    }

    func testUpstreamTracestateMembersArePropagatedAndOursGoesFirst() async throws {
        let p = TracePipeline(configuration: config(), clock: ManualClock(), ids: SeededIDSource(seed: 11))
        let h = await p.startTrace("push", continuing: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-03",
                                   tracestate: "rojo=00f067aa0ba902b7, tokentrace=stale ,congo=t61rcWkgMzE")
        let req = await p.startSpan("req", kind: .client, parent: h)
        let healthy = await p.tracestate(for: req)
        XCTAssertEqual(healthy, "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE")
        let local = await p.startSpan("local", parent: h)
        await p.end(local, status: .refused)
        let notable = await p.tracestate(for: req)
        XCTAssertEqual(notable, "tokentrace=k,rojo=00f067aa0ba902b7,congo=t61rcWkgMzE")
        let many = (0..<40).map { "v\($0)=x" }.joined(separator: ",")
        XCTAssertEqual(TraceStateKey.foreignMembers(many).count, 31)
    }

    func testContinuedTraceWithoutTheRandomFlagDoesNotInventIt() async throws {
        let p = TracePipeline(configuration: config(), clock: ManualClock(), ids: SeededIDSource(seed: 10))
        let notRandom = await p.startTrace("push", continuing: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
        let h1 = await p.traceparent(for: notRandom)
        XCTAssertEqual(try XCTUnwrap(TraceParent.parse(h1)).flags, [.sampled])
        let random = await p.startTrace("push", continuing: "00-5bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-03")
        let h2 = await p.traceparent(for: random)
        XCTAssertEqual(try XCTUnwrap(TraceParent.parse(h2)).flags, [.sampled, .random])
    }

    func testDurationsUseTheMonotonicClockEvenIfTheWallClockJumps() async throws {
        let clock = ManualClock()
        let p = TracePipeline(configuration: config(ratio: 1, skew: false), clock: clock, ids: SeededIDSource(seed: 6))
        let r = await p.startTrace("tap")
        clock.advance(millis: 100)
        clock.jumpWall(byNanos: -3_600_000_000_000) // NTP sets the clock back an hour mid-trace
        clock.advance(millis: 100)
        let ended = await p.end(r)
        let o = try XCTUnwrap(ended)
        XCTAssertEqual(o.rootDurationNanos, 200_000_000)
        let s = try XCTUnwrap(o.exported.first)
        XCTAssertEqual(s.endUnixNanos - s.startUnixNanos, 200_000_000)
    }

    func testSweepTurnsAHungRequestIntoAKeptAbandonedTrace() async throws {
        let clock = ManualClock()
        let p = TracePipeline(configuration: config(ratio: 0, limits: TraceLimits(traceTimeoutNanos: 10_000_000_000)),
                              clock: clock, ids: SeededIDSource(seed: 7))
        let r = await p.startTrace("tap")
        _ = await p.startSpan("hung", kind: .client, parent: r)
        await p.end(r)
        clock.advance(millis: 10_000)
        let out = await p.sweep()
        let o = try XCTUnwrap(out.first)
        XCTAssertTrue(o.decision.isForced)
        XCTAssertTrue(o.bufferAccepted)
        XCTAssertEqual(o.exported.first { $0.name == "hung" }?.status, .abandoned)
    }

    func testManyConcurrentTracesAreAllAccountedFor() async {
        // Ratio 0: the only kept traces are the forced ones, so the count is exact.
        let p = TracePipeline(configuration: config(ratio: 0, limits: TraceLimits(maxOpenTraces: 1_000)),
                              clock: SystemClock(), ids: RandomIDSource())
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<200 {
                g.addTask {
                    let r = await p.startTrace("tap", attributes: [AttributeKey.feature: .string("f\(i % 3)")])
                    let c = await p.startSpan("child", parent: r)
                    await p.setAttribute(AttributeKey.tier, .string("on-device"), on: c)
                    await p.end(c, status: i % 10 == 0 ? .refused : .ok)
                    await p.end(r)
                }
            }
        }
        let m = await p.metrics()
        XCTAssertEqual(m.tracesKept + m.tracesDropped, 200)
        XCTAssertEqual(m.tracesKept, 20, "exactly the 20 refusals are kept")
        XCTAssertEqual(m.tracesRefusedByBuffer, 0)
        let total = await p.costReport().reduce(0) { $0 + $1.traces }
        XCTAssertEqual(total, 200)
        XCTAssertEqual(m.assembly.unknownOrEndedSpanOperations, 0)
    }

    func testLimitsHitUnderLoadDegradeToNonRecordingWithoutCrashing() async {
        let p = TracePipeline(configuration: config(limits: TraceLimits(maxOpenTraces: 2, maxSpansPerTrace: 2)),
                              clock: ManualClock(), ids: SeededIDSource(seed: 8))
        var roots: [SpanHandle] = []
        for _ in 0..<5 { roots.append(await p.startTrace("tap")) }
        XCTAssertEqual(roots.filter(\.isRecording).count, 2)
        for r in roots {
            let c = await p.startSpan("c", parent: r)
            await p.end(c)
            await p.end(r)
            await p.end(r)
        }
        let m = await p.metrics()
        XCTAssertEqual(m.assembly.tracesRefused, 3)
        XCTAssertEqual(m.tracesKept + m.tracesDropped, 2)
    }
}

// MARK: - End to end, through the lab

final class TraceLabTests: XCTestCase {
    func lab(skew: Bool = true, ratio: Double = 0.05) -> TraceLab {
        TraceLab(configuration: TracingConfiguration(sampling: SamplingPolicy(healthyKeepRatio: ratio),
                                                     prices: LabPrices.table, hashKey: Array("demo".utf8),
                                                     installID: "lab", applySkewCorrection: skew))
    }

    /// The demo's default state: what the user sees after the first tap.
    func testDefaultScenarioProducesAKeptCorrectedWaterfall() async throws {
        let run = await lab().run(LabScenario())
        let o = try XCTUnwrap(run.outcome)
        XCTAssertEqual(o.decision, .keep([.refused]))
        XCTAssertTrue(run.serverKept, "tracestate asked the server to keep its half")
        XCTAssertEqual(run.tracestateSent, ["tokentrace=k"])
        XCTAssertEqual(Set(run.merged.map(\.source)), ["device", "edge-proxy", "vendor"])
        XCTAssertEqual(run.merged.count, 5) // root, on-device, request + proxy, vendor
        XCTAssertEqual(o.appliedOffsetNanos, -2_400_000_000)
        XCTAssertEqual(run.orderingViolations, 0)
        XCTAssertEqual(o.costPicoDollars, 317_000_000)
    }

    /// Skew correction is what keeps the waterfall coherent, and the
    /// violation counter is what proves it: turn correction off and it fires.
    func testWithoutSkewCorrectionServerSpansLandBeforeTheirParent() async throws {
        let run = await lab(skew: false).run(LabScenario(deviceClockAheadMillis: 2_400))
        XCTAssertEqual(run.outcome?.appliedOffsetNanos, 0)
        XCTAssertGreaterThan(run.orderingViolations, 0)
        let behind = await lab(skew: false).run(LabScenario(deviceClockAheadMillis: -1_500))
        XCTAssertGreaterThan(behind.orderingViolations, 0)
        let corrected = await lab(skew: true).run(LabScenario(deviceClockAheadMillis: -1_500))
        XCTAssertEqual(corrected.orderingViolations, 0)
    }

    func testPromptAndPIINeverReachTheExporterButWereRecorded() async throws {
        let run = await lab().run(LabScenario(cloud: .fails))
        let o = try XCTUnwrap(run.outcome)
        // Recorded (so the test is not vacuous)...
        XCTAssertNotNil(o.recorded.root?.attributes["debug.prompt"])
        // ...but not exported.
        let blob = o.exported.flatMap { $0.attributes.values.map(\.description) }.joined(separator: " ")
        // Multi-character secrets that cannot occur by chance inside a hex digest.
        for secret in ["Jane", "+1 415", "4111 1111", "jane.doe", "user-8812"] {
            XCTAssertFalse(blob.contains(secret), "leaked \(secret): \(blob)")
        }
        XCTAssertTrue(blob.contains("[email]"))
        XCTAssertNotNil(o.exported.first?.attributes[AttributeKey.promptDigest])
        XCTAssertEqual(o.exported.first?.attributes[AttributeKey.promptLengthBucket], .string("64-255"))
    }

    func testRateLimitedRetryIsTwoClientSpansOfOneTrace() async throws {
        let run = await lab().run(LabScenario(cloud: .rateLimitedOnce))
        XCTAssertEqual(run.traceparentSent.count, 2)
        let parsed = run.traceparentSent.compactMap(TraceParent.parse)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].traceID, parsed[1].traceID)
        XCTAssertNotEqual(parsed[0].parentID, parsed[1].parentID)
        let o = try XCTUnwrap(run.outcome)
        let reqs = o.exported.filter { $0.name == "ai.cloud.request" }
        XCTAssertEqual(reqs.map(\.status), [.error(code: "http.429"), .ok])
        XCTAssertEqual(run.orderingViolations, 0)
    }

    func testSlowVendorIsKeptAsSlowAndHealthyOnDeviceIsRatioSampled() async throws {
        let slow = await lab().run(LabScenario(onDevice: .refuses, cloud: .slow))
        let reasons: [KeepReason]
        if case .keep(let r) = try XCTUnwrap(slow.outcome).decision { reasons = r } else { reasons = [] }
        XCTAssertTrue(reasons.contains { if case .slow = $0 { return true } else { return false } })

        let l = lab(ratio: 0)
        let healthy = await l.run(LabScenario(onDevice: .answers))
        XCTAssertEqual(healthy.outcome?.decision, .drop)
        XCTAssertTrue(healthy.serverSpans.isEmpty)
        XCTAssertTrue(healthy.traceparentSent.isEmpty)
    }

    /// The blocker from review, end to end: move the clock between runs of
    /// one lab and the corrected waterfall must stay coherent.
    func testChangingTheDeviceClockBetweenRunsKeepsTheWaterfallCoherent() async throws {
        let l = lab()
        for ahead: Int64 in [2_400, -1_000, 5_000, 0] {
            let run = await l.run(LabScenario(deviceClockAheadMillis: ahead))
            let o = try XCTUnwrap(run.outcome)
            XCTAssertEqual(o.appliedOffsetNanos, -ahead * 1_000_000, "ahead \(ahead)")
            XCTAssertEqual(run.orderingViolations, 0, "ahead \(ahead)")
        }
    }

    func testOverlappingRunsAreSerializedAndEachStaysCoherent() async throws {
        let l = lab()
        // Deterministic overlap: run A parks inside the lock; run B is then
        // started and given ample time. With serialization B cannot reach the
        // hook until A finishes; without it, B reaches it while A is parked.
        let probe = RunProbe()
        await l.setRunHook { await probe.enter() }
        let a = Task { await l.run(LabScenario(cloud: .rateLimitedOnce)) }
        await probe.waitForEntries(1)
        let b = Task { await l.run(LabScenario(onDevice: .unavailable, cloud: .slow)) }
        try await Task.sleep(nanoseconds: 200_000_000)
        let enteredWhileAParked = await probe.entries
        XCTAssertEqual(enteredWhileAParked, 1, "run B entered while run A held the lab")
        await probe.releaseAll()
        let runs = [await a.value, await b.value]
        for r in runs {
            XCTAssertEqual(r.orderingViolations, 0)
            let o = try XCTUnwrap(r.outcome)
            // Each run's own duration, as if run alone.
            let solo = await lab().run(r.scenario)
            XCTAssertEqual(o.rootDurationNanos, try XCTUnwrap(solo.outcome).rootDurationNanos)
        }
    }

    func testAbsurdLimitsAreClampedInsteadOfOverflowing() async throws {
        let limits = TraceLimits(maxOpenTraces: .max, maxSpansPerTrace: .max)
        XCTAssertEqual(limits.maxOpenTraces, 100_000)
        var a = TraceAssembly(limits: limits)
        let ids = SeededIDSource(seed: 1)
        let r = a.startTrace(name: "r", kind: .interaction, traceID: ids.nextTraceID(), spanID: ids.nextSpanID(),
                             remoteParent: nil, nowMono: 1, nowWall: 0)
        XCTAssertNotNil(a.end(r, status: .ok, nowMono: 2)) // completing used to multiply the limit by 4
        XCTAssertEqual(BufferLimits(maxSpans: .max).maxSpans, 1_000_000)
    }

    func testRepeatedFlushesDoNotAgeOutTheClockEstimate() async throws {
        let l = lab(ratio: 1) // keep the healthy on-device trace so its offset is computed
        _ = await l.run(LabScenario())
        for _ in 0..<5 { _ = await l.flush() }
        let local = await l.run(LabScenario(onDevice: .answers))
        // The on-device run takes no new sample; the old one must still apply.
        XCTAssertEqual(local.outcome?.appliedOffsetNanos, -2_400_000_000)
    }

    func testLostAckIsRetriedWithTheSameIDAndDedupedByTheCollector() async throws {
        let l = lab()
        _ = await l.run(LabScenario())
        await l.setLosesAcks(true)
        let first = await l.flush()
        guard case .backingOff = first else { return XCTFail("expected retry, got \(first)") }
        await l.setLosesAcks(false)
        let second = await l.flush()
        XCTAssertEqual(second, .exported(batches: 1, spans: 3))
        let dups = await l.collector.duplicateBatches
        let ids = await l.collector.batchIDs
        XCTAssertEqual(dups, 1, "the retry carried the same id")
        XCTAssertEqual(ids, ["lab-1"])
        let deviceSpans = await l.collector.spans.filter { $0.source == "device" }.count
        XCTAssertEqual(deviceSpans, 3, "stored once despite two deliveries")
    }

    func testOfflineBufferingThenFlushDeliversExactlyOnce() async throws {
        let l = lab()
        await l.setOnline(false)
        _ = await l.run(LabScenario())
        _ = await l.run(LabScenario(onDevice: .unavailable))
        let offline = await l.flush()
        guard case .backingOff = offline else { return XCTFail("expected backoff, got \(offline)") }
        let held = await l.pipeline.buffer.hasPendingRetry
        XCTAssertTrue(held)
        await l.setOnline(true)
        let online = await l.flush()
        XCTAssertEqual(online, .exported(batches: 1, spans: 6))
        let deviceSpans = await l.collector.spans.filter { $0.source == "device" }.count
        XCTAssertEqual(deviceSpans, 6)
        let again = await l.flush()
        XCTAssertEqual(again, .nothingToSend)
        let dups = await l.collector.duplicateBatches
        XCTAssertEqual(dups, 0)
    }
}
