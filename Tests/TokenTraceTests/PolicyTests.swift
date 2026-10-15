import XCTest
@testable import TokenTrace

final class TraceAssemblyTests: XCTestCase {
    let ids = SeededIDSource(seed: 1)

    func root(_ a: inout TraceAssembly, at t: UInt64 = 100) -> SpanHandle {
        a.startTrace(name: "root", kind: .interaction, traceID: ids.nextTraceID(), spanID: ids.nextSpanID(),
                     remoteParent: nil, nowMono: t, nowWall: 0)
    }

    func testTraceCompletesOnlyWhenRootAndEveryChildHaveEnded() throws {
        var a = TraceAssembly()
        let r = root(&a)
        let c = a.startSpan(name: "stream", kind: .client, parent: r, spanID: ids.nextSpanID(), nowMono: 110)
        // The child outlives the root (a streamed response).
        XCTAssertNil(a.end(r, status: .ok, nowMono: 200))
        XCTAssertEqual(a.openTraceCount, 1)
        let t = try XCTUnwrap(a.end(c, status: .ok, nowMono: 900))
        XCTAssertEqual(t.spans.count, 2)
        XCTAssertEqual(t.spans.first?.spanID, r.spanID) // sorted by start
        XCTAssertEqual(t.reason, .finished)
        XCTAssertEqual(a.openTraceCount, 0)
    }

    func testEndIsIdempotentAndATraceCompletesOnce() {
        var a = TraceAssembly()
        let r = root(&a)
        XCTAssertNotNil(a.end(r, status: .ok, nowMono: 200))
        XCTAssertNil(a.end(r, status: .error(code: "x"), nowMono: 300))
        XCTAssertEqual(a.counters.unknownOrEndedSpanOperations, 1)
    }

    func testSpanStartedAfterItsTraceCompletedIsLateAndNotRecorded() {
        var a = TraceAssembly()
        let r = root(&a)
        _ = a.end(r, status: .ok, nowMono: 200)
        let late = a.startSpan(name: "late", kind: .internal, parent: r, spanID: ids.nextSpanID(), nowMono: 300)
        XCTAssertFalse(late.isRecording)
        XCTAssertEqual(late.traceID, r.traceID, "still propagates the same trace id")
        XCTAssertEqual(a.counters.lateSpans, 1)
        XCTAssertNil(a.end(late, status: .ok, nowMono: 400))
    }

    func testPerTraceSpanLimitIsEnforcedAndReported() throws {
        var a = TraceAssembly(limits: TraceLimits(maxSpansPerTrace: 3))
        let r = root(&a)
        var kids: [SpanHandle] = []
        for _ in 0..<5 { kids.append(a.startSpan(name: "c", kind: .internal, parent: r, spanID: ids.nextSpanID(), nowMono: 150)) }
        XCTAssertEqual(kids.filter(\.isRecording).count, 2)
        for k in kids { _ = a.end(k, status: .ok, nowMono: 160) }
        let t = try XCTUnwrap(a.end(r, status: .ok, nowMono: 170))
        XCTAssertEqual(t.spans.count, 3)
        XCTAssertEqual(t.droppedSpans, 3)
    }

    func testOpenTraceLimitReturnsNonRecordingHandles() {
        var a = TraceAssembly(limits: TraceLimits(maxOpenTraces: 2))
        _ = root(&a); _ = root(&a)
        let third = root(&a)
        XCTAssertFalse(third.isRecording)
        XCTAssertEqual(a.counters.tracesRefused, 1)
        // Operations on it are harmless no-ops.
        a.setAttribute("k", .int(1), on: third)
        XCTAssertNil(a.end(third, status: .ok, nowMono: 1))
        XCTAssertEqual(a.openTraceCount, 2)
    }

    func testSweepForceEndsOpenSpansAsAbandonedOnlyAfterTheTimeout() throws {
        var a = TraceAssembly(limits: TraceLimits(traceTimeoutNanos: 1_000))
        let r = root(&a, at: 100)
        _ = a.startSpan(name: "hung", kind: .client, parent: r, spanID: ids.nextSpanID(), nowMono: 150)
        XCTAssertTrue(a.sweep(nowMono: 1_099).isEmpty)
        let done = a.sweep(nowMono: 1_100)
        let t = try XCTUnwrap(done.first)
        XCTAssertEqual(t.reason, .timedOut)
        XCTAssertTrue(t.spans.allSatisfy { $0.status == .abandoned })
        XCTAssertEqual(t.spans.map(\.endMono), [1_100, 1_100])
        XCTAssertEqual(a.counters.tracesTimedOut, 1)
    }

    func testAttributeLimitsTruncationAndKeyValidation() throws {
        var a = TraceAssembly(limits: TraceLimits(maxAttributesPerSpan: 2, maxStringValueLength: 4))
        let r = root(&a)
        a.setAttribute("a", .string("abcdefgh"), on: r)
        a.setAttribute("b", .int(1), on: r)
        a.setAttribute("c", .int(2), on: r)               // over the limit
        a.setAttribute("b", .int(3), on: r)               // overwrite is allowed at the limit
        a.setAttribute("", .int(4), on: r)                // empty key
        a.setAttribute(String(repeating: "k", count: 200), .int(5), on: r)
        let t = try XCTUnwrap(a.end(r, status: .ok, nowMono: 200))
        let attrs = try XCTUnwrap(t.root).attributes
        XCTAssertEqual(attrs, ["a": .string("abcd"), "b": .int(3)])
        XCTAssertEqual(a.counters.attributesRefused, 3)
    }

    func testChildOfAnUnknownParentIsRefused() throws {
        var a = TraceAssembly()
        let r = root(&a)
        let bogusParent = SpanHandle(traceID: r.traceID, spanID: try XCTUnwrap(SpanID(0xdead)), isRecording: true)
        XCTAssertFalse(a.startSpan(name: "x", kind: .internal, parent: bogusParent, spanID: ids.nextSpanID(), nowMono: 1).isRecording)
    }

    func testEventLimit() throws {
        var a = TraceAssembly(limits: TraceLimits(maxEventsPerSpan: 1))
        let r = root(&a)
        a.addEvent("one", on: r, nowMono: 120)
        a.addEvent("two", on: r, nowMono: 130)
        let t = try XCTUnwrap(a.end(r, status: .ok, nowMono: 200))
        XCTAssertEqual(t.root?.events.map(\.name), ["one"])
        XCTAssertEqual(a.counters.eventsRefused, 1)
    }

    func testNotableSpanIsVisibleBeforeTheTraceEnds() {
        var a = TraceAssembly()
        let r = root(&a)
        let c = a.startSpan(name: "local", kind: .internal, parent: r, spanID: ids.nextSpanID(), nowMono: 110)
        XCTAssertFalse(a.hasNotableSpan(r.traceID))
        _ = a.end(c, status: .refused, nowMono: 120)
        XCTAssertTrue(a.hasNotableSpan(r.traceID))
    }
}

final class RedactionTests: XCTestCase {
    let key: [UInt8] = Array("install-secret".utf8)

    func redact(_ attrs: [String: AttributeValue], policy: AttributePolicy = .standard,
                key: [UInt8]? = nil) -> ([String: AttributeValue], RedactionCounters) {
        var c = RedactionCounters()
        let out = Redactor(policy: policy, hashKey: key ?? self.key).redact(attrs, counters: &c)
        return (out, c)
    }

    func testUnclassifiedKeysAreDroppedAndNamed() {
        let (out, c) = redact(["debug.prompt": .string("call Jane"), AttributeKey.feature: .string("f")])
        XCTAssertEqual(out, [AttributeKey.feature: .string("f")])
        XCTAssertEqual(c.unclassifiedKeys, ["debug.prompt"])
    }

    func testHashedValuesCorrelateWithinAnInstallButNotAcross() {
        let a = redact([AttributeKey.userID: .string("user-1")]).0[AttributeKey.userID]
        let b = redact([AttributeKey.userID: .string("user-1")]).0[AttributeKey.userID]
        let other = redact([AttributeKey.userID: .string("user-1")], key: [9, 9]).0[AttributeKey.userID]
        let different = redact([AttributeKey.userID: .string("user-2")]).0[AttributeKey.userID]
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, other)
        XCTAssertNotEqual(a, different)
        XCTAssertFalse(a?.stringValue?.contains("user-1") ?? true)
    }

    func testScannedTextMasksEmailCardAndPhone() {
        let msg = "quota for jane.doe@example.com, card 4111 1111 1111 1111, call +1 415-555-0100, order 12"
        let out = redact([AttributeKey.errorMessage: .string(msg)]).0[AttributeKey.errorMessage]?.stringValue ?? ""
        XCTAssertEqual(out, "quota for [email], card [card], call [phone], order 12")
    }

    func testDigitRunThatFailsLuhnIsTreatedAsAPhoneNotACard() {
        XCTAssertEqual(PIIScanner.scrub("4111 1111 1111 1112"), "[phone]")
        XCTAssertTrue(PIIScanner.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
        XCTAssertFalse(PIIScanner.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]))
        XCTAssertFalse(PIIScanner.luhn([]))
        XCTAssertFalse(PIIScanner.luhn([12]))
    }

    func testExactRulesBeatPrefixesAndTheLongestPrefixWins() {
        let p = AttributePolicy(exact: ["a.b.secret": .drop], prefixes: ["a.": .drop, "a.b.": .allow])
        XCTAssertEqual(p.classify("a.b.count"), .allow)
        XCTAssertEqual(p.classify("a.x"), .drop)
        XCTAssertEqual(p.classify("a.b.secret"), .drop)
        XCTAssertEqual(p.classify("z"), .drop)
        // A key dropped by an explicit prefix rule was classified on purpose.
        let (_, c) = redact(["a.x": .int(1)], policy: p)
        XCTAssertTrue(c.unclassifiedKeys.isEmpty)
    }

    /// The README's claim: a prompt put into a span by mistake never leaves
    /// the device. The check must also *fail* on a policy that is broken.
    func leaksPrompt(_ policy: AttributePolicy) -> Bool {
        let secret = "call Jane on +1 415 555 0100"
        let (out, _) = redact(["debug.prompt": .string(secret), "debug.raw": .string(secret)], policy: policy)
        return out.values.contains { $0.stringValue?.contains("Jane") ?? false }
    }

    func testDefaultDenyPolicyDoesNotLeakAndAPermissiveOneIsCaught() {
        XCTAssertFalse(leaksPrompt(.standard))
        var permissive = AttributePolicy.standard
        permissive.unclassified = .allow
        XCTAssertTrue(leaksPrompt(permissive), "the leak check must detect a broken policy")
    }

    func testSensitiveTextBucketsAndDigest() {
        XCTAssertEqual(SensitiveText("").lengthBucket, "0")
        XCTAssertEqual(SensitiveText(String(repeating: "x", count: 63)).lengthBucket, "1-63")
        XCTAssertEqual(SensitiveText(String(repeating: "x", count: 64)).lengthBucket, "64-255")
        XCTAssertEqual(SensitiveText(String(repeating: "x", count: 5_000)).lengthBucket, "4096+")
        let d1 = SensitiveText("hello").digest(key: key)
        XCTAssertEqual(d1, SensitiveText("hello").digest(key: key))
        XCTAssertNotEqual(d1, SensitiveText("hello").digest(key: [1]))
        XCTAssertEqual(d1.count, 16)
    }

    func testSensitiveTextDoesNotLeakThroughStringConversion() {
        let t = SensitiveText("secret prompt about Jane")
        var dumped = ""
        dump(t, to: &dumped)
        for rendered in ["\(t)", String(describing: t), String(reflecting: t), dumped,
                         "\(Mirror(reflecting: t).children.map { "\($0.value)" })"] {
            XCTAssertFalse(rendered.contains("Jane"), rendered)
        }
        XCTAssertEqual("\(t)", "<redacted>")
    }

    func testUnclassifiedKeyListIsBounded() {
        let attrs = Dictionary(uniqueKeysWithValues: (0..<100).map { ("k\($0)", AttributeValue.int(1)) })
        XCTAssertEqual(redact(attrs).1.unclassifiedKeys.count, 64)
    }
}

final class TailSamplerTests: XCTestCase {
    func trace(id: TraceID, statuses: [SpanStatus] = [.ok], duration: UInt64 = 1_000, reason: CompletionReason = .finished) -> CompletedTrace {
        var spans: [FinishedSpan] = []
        for (i, st) in statuses.enumerated() {
            // Index + 1 is never zero.
            spans.append(FinishedSpan(spanID: SpanID(UInt64(i + 1))!, parentID: i == 0 ? nil : SpanID(1),
                                      name: "s", kind: .internal, startMono: 0, endMono: i == 0 ? duration : 1,
                                      attributes: [:], events: [], status: st))
        }
        return CompletedTrace(traceID: id, rootSpanID: SpanID(1)!, remoteParentID: nil, anchorWall: 0, anchorMono: 0,
                              spans: spans, droppedSpans: 0, reason: reason)
    }

    let ids = SeededIDSource(seed: 99)

    func testNotableTracesAreAlwaysKeptEvenAtRatioZero() {
        let s = TailSampler(policy: SamplingPolicy(latencySLONanos: 10_000, costThresholdPicoDollars: 500, healthyKeepRatio: 0))
        XCTAssertEqual(s.decide(trace(id: ids.nextTraceID(), statuses: [.ok, .error(code: "e")]), costPicoDollars: 0), .keep([.error]))
        XCTAssertEqual(s.decide(trace(id: ids.nextTraceID(), statuses: [.ok, .refused]), costPicoDollars: 0), .keep([.refused]))
        XCTAssertEqual(s.decide(trace(id: ids.nextTraceID(), statuses: [.ok, .fallback(reason: "r")]), costPicoDollars: 0), .keep([.fallback]))
        XCTAssertEqual(s.decide(trace(id: ids.nextTraceID(), statuses: [.abandoned], reason: .timedOut), costPicoDollars: 0), .keep([.abandoned]))
        XCTAssertEqual(s.decide(trace(id: ids.nextTraceID(), duration: 10_000), costPicoDollars: 0), .keep([.slow(durationNanos: 10_000)]))
        XCTAssertEqual(s.decide(trace(id: ids.nextTraceID()), costPicoDollars: 500), .keep([.expensive(picoDollars: 500)]))
        XCTAssertEqual(s.decide(trace(id: ids.nextTraceID()), costPicoDollars: 499), .drop)
    }

    func testRatioEdgesAndGarbage() {
        let t = trace(id: ids.nextTraceID())
        XCTAssertEqual(TailSampler(policy: SamplingPolicy(healthyKeepRatio: 1)).decide(t, costPicoDollars: nil), .keep([.ratio]))
        XCTAssertEqual(TailSampler(policy: SamplingPolicy(healthyKeepRatio: 7)).decide(t, costPicoDollars: nil), .keep([.ratio]))
        XCTAssertEqual(TailSampler(policy: SamplingPolicy(healthyKeepRatio: 0)).decide(t, costPicoDollars: nil), .drop)
        XCTAssertEqual(TailSampler(policy: SamplingPolicy(healthyKeepRatio: -1)).decide(t, costPicoDollars: nil), .drop)
        XCTAssertEqual(TailSampler(policy: SamplingPolicy(healthyKeepRatio: .nan)).decide(t, costPicoDollars: nil), .drop)
        XCTAssertEqual(SamplingPolicy(healthyKeepRatio: 1).rejectionThreshold56, 0)
        XCTAssertEqual(SamplingPolicy(healthyKeepRatio: 0).rejectionThreshold56, 1 << 56)
        XCTAssertEqual(SamplingPolicy(healthyKeepRatio: 0.25).rejectionThreshold56, 3 << 54)
    }

    /// Consistency property: a trace kept at ratio r is kept at every r' > r,
    /// and the realized fraction tracks r. Checked against a deliberately
    /// broken sampler as well, so the check itself is known to bite.
    func violatesConsistency(_ decide: (TraceID, Double) -> Bool) -> Bool {
        let source = SeededIDSource(seed: 2026)
        let traces = (0..<4_000).map { _ in source.nextTraceID() }
        let ratios = [0.01, 0.05, 0.1, 0.25, 0.5]
        var previous: Set<TraceID> = []
        for r in ratios {
            let kept = Set(traces.filter { decide($0, r) })
            if !previous.isSubset(of: kept) { return true }
            let fraction = Double(kept.count) / Double(traces.count)
            if abs(fraction - r) > max(0.01, r * 0.25) { return true }
            previous = kept
        }
        return false
    }

    func testRatioSamplingIsConsistentAndTheCheckCatchesABrokenSampler() {
        let real: (TraceID, Double) -> Bool = { id, r in
            let t = self.trace(id: id)
            return TailSampler(policy: SamplingPolicy(latencySLONanos: .max, healthyKeepRatio: r))
                .decide(t, costPicoDollars: nil).isKept
        }
        XCTAssertFalse(violatesConsistency(real))

        // Broken: an independent coin per decision (what `Double.random` gives you).
        var g = SplitMix(seed: 5)
        let coin: (TraceID, Double) -> Bool = { _, r in g.nextUnit() < r }
        XCTAssertTrue(violatesConsistency(coin))

        // Broken: the keep-band is scaled to 2^50 instead of 2^56, so it still
        // nests (passes the subset test) but keeps ~64x too few traces.
        let scaled: (TraceID, Double) -> Bool = { id, r in
            id.randomness56 >= (UInt64(1) << 56) - Saturating.uint64(r * Double(UInt64(1) << 50))
        }
        XCTAssertTrue(violatesConsistency(scaled))
    }

    func testClientAndServerRuleAgreeFromTheTraceIDAlone() {
        let policy = SamplingPolicy(latencySLONanos: .max, healthyKeepRatio: 0.3)
        for _ in 0..<500 {
            let id = ids.nextTraceID()
            let client = TailSampler(policy: policy).decide(trace(id: id), costPicoDollars: nil).isKept
            // What an OTel probability sampler computes: keep iff R >= T, T = (1 - p) * 2^56.
            let t = UInt64((1 - 0.3) * Double(UInt64(1) << 56))
            let server = id.randomness56 >= t
            XCTAssertEqual(client, server)
        }
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

final class CostTests: XCTestCase {
    func llmTrace(model: String?, input: Int64, output: Int64, cache: Int64 = 0, feature: String = "f",
                  duration: UInt64 = 100, status: SpanStatus = .ok) -> CompletedTrace {
        var attrs: [String: AttributeValue] = [AttributeKey.inputTokens: .int(input), AttributeKey.outputTokens: .int(output),
                                               AttributeKey.cacheReadTokens: .int(cache)]
        if let model { attrs[AttributeKey.model] = .string(model) }
        // Literal non-zero ids.
        let root = FinishedSpan(spanID: SpanID(1)!, parentID: nil, name: "r", kind: .interaction, startMono: 0,
                                endMono: duration, attributes: [AttributeKey.feature: .string(feature)], events: [], status: .ok)
        let call = FinishedSpan(spanID: SpanID(2)!, parentID: SpanID(1), name: "c", kind: .client, startMono: 1,
                                endMono: 2, attributes: attrs, events: [], status: status)
        return CompletedTrace(traceID: TraceID(high: 1, low: 1)!, rootSpanID: SpanID(1)!, remoteParentID: nil,
                              anchorWall: 0, anchorMono: 0, spans: [root, call], droppedSpans: 0, reason: .finished)
    }

    func testPricingIsExactIntegerPicoDollars() {
        let c = LabPrices.table.cost(of: llmTrace(model: LabPrices.cloudModel, input: 1_850, output: 240, cache: 1_200))
        // 1850×0.10 + 240×0.50 + 1200×0.01 dollars per million tokens.
        XCTAssertEqual(c.picoDollars, 317_000_000)
        XCTAssertEqual(Money.format(picoDollars: c.picoDollars), "$0.000317")
        XCTAssertEqual(c.calls, 1)
        XCTAssertEqual(c.unpriced, 0)
    }

    func testUnknownModelIsReportedNotPricedAtZero() {
        let c = LabPrices.table.cost(of: llmTrace(model: "mystery-model", input: 10, output: 10))
        XCTAssertEqual(c.unpriced, 1)
        XCTAssertEqual(c.picoDollars, 0)
        let missing = LabPrices.table.cost(of: llmTrace(model: nil, input: 10, output: 10))
        XCTAssertEqual(missing.unpriced, 1)
    }

    func testAbsurdTokenCountsSaturateAndNegativesClamp() {
        let huge = LabPrices.table.cost(of: llmTrace(model: LabPrices.cloudModel, input: .max, output: .max))
        XCTAssertEqual(huge.picoDollars, .max)
        let negative = LabPrices.table.cost(of: llmTrace(model: LabPrices.cloudModel, input: -5, output: -5))
        XCTAssertEqual(negative.picoDollars, 0)
    }

    func testPercentiles() {
        XCTAssertEqual(CostAttributor.percentile([], 50), 0)
        XCTAssertEqual(CostAttributor.percentile([7], 95), 7)
        let xs = (1...100).map(UInt64.init)
        XCTAssertEqual(CostAttributor.percentile(xs, 50), 50)
        XCTAssertEqual(CostAttributor.percentile(xs, 95), 95)
        XCTAssertEqual(CostAttributor.percentile(xs, 100), 100)
        XCTAssertEqual(CostAttributor.percentile(xs, 0), 1)
        XCTAssertEqual(CostAttributor.percentile(xs, 250), 100)
        XCTAssertEqual(CostAttributor.percentile([1, 2, 3], 50), 2)
    }

    func testFeatureCardinalityIsBounded() {
        var a = CostAttributor(prices: LabPrices.table, maxFeatures: 2)
        for f in ["a", "b", "c", "d"] { a.record(llmTrace(model: LabPrices.cloudModel, input: 1, output: 1, feature: f)) }
        let names = a.report().map(\.feature)
        XCTAssertEqual(names, ["(other)", "a", "b"])
        XCTAssertEqual(a.report().first?.traces, 2)
    }

    func testLatencyWindowIsBoundedAndFallbacksCounted() {
        var a = CostAttributor(prices: LabPrices.table, latencyWindow: 3)
        for d in [100, 200, 300, 400, 500] as [UInt64] { a.record(llmTrace(model: nil, input: 1, output: 1, duration: d)) }
        a.record(llmTrace(model: nil, input: 1, output: 1, duration: 600, status: .fallback(reason: "x")))
        let r = a.report()[0]
        XCTAssertEqual(r.traces, 6)
        XCTAssertEqual(r.p50Nanos, 500) // window holds 400, 500, 600
        XCTAssertEqual(r.fallbackTraces, 1)
    }

    func testMoneyFormatting() {
        XCTAssertEqual(Money.format(picoDollars: 0), "$0.00")
        XCTAssertEqual(Money.format(picoDollars: 1_000_000_000_000), "$1.00")
        XCTAssertEqual(Money.format(picoDollars: -1_500_000_000_000), "-$1.50")
        XCTAssertEqual(Money.format(picoDollars: 12_345), "$0.00000001")
        XCTAssertEqual(Money.format(picoDollars: 31_250_000), "$0.00003125")
        XCTAssertEqual(Money.format(picoDollars: .min), "-$9223372.03685477")
    }
}
