import XCTest
import Foundation
#if canImport(Glibc)
import Glibc
#endif
@testable import TokenTrace

final class TraceParentTests: XCTestCase {
    func testW3CSpecExampleRoundTrips() throws {
        let raw = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        let tp = try XCTUnwrap(TraceParent.parse(raw))
        XCTAssertEqual(tp.traceID.hex, "4bf92f3577b34da6a3ce929d0e0e4736")
        XCTAssertEqual(tp.parentID.hex, "00f067aa0ba902b7")
        XCTAssertEqual(tp.flags, .sampled)
        XCTAssertEqual(tp.headerValue, raw)
        XCTAssertEqual(tp.headerValue.utf8.count, 55)
    }

    func testInvalidHeadersAreRejectedNotRepaired() {
        let bad = [
            "",
            "00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",   // uppercase
            "00-00000000000000000000000000000000-00f067aa0ba902b7-01",   // zero trace id
            "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",   // zero parent id
            "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",   // forbidden version
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-x", // v00 with trailing data
            "00_4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",   // wrong separator
            "00-4bf92f3577b34da6a3ce929d0e0e473-600f067aa0ba902b7-01",   // dash in the wrong place
            "00-4bf92f3577b34da6a3ce929d0e0e47é6-00f067aa0ba902b7-01",   // non-ASCII
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-0g",   // bad flags
            "01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01x",  // future version, no dash
            String(repeating: "0", count: 600)
        ]
        for b in bad { XCTAssertNil(TraceParent.parse(b), "accepted: \(b)") }
    }

    func testFutureVersionWithExtraFieldsIsAccepted() throws {
        let tp = try XCTUnwrap(TraceParent.parse("cc-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-whatever"))
        XCTAssertEqual(tp.traceID.hex, "4bf92f3577b34da6a3ce929d0e0e4736")
        // We always re-emit the version we implement.
        XCTAssertTrue(tp.headerValue.hasPrefix("00-"))
    }

    func testUnknownFlagBitsAreNotPropagated() throws {
        let tp = try XCTUnwrap(TraceParent.parse("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-ff"))
        XCTAssertTrue(tp.headerValue.hasSuffix("-03"))
    }

    func testWhitespaceAroundTheValueIsTolerated() {
        XCTAssertNotNil(TraceParent.parse(" 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01\t"))
    }

    func testHexFormattingPadsSmallValues() throws {
        XCTAssertEqual(try XCTUnwrap(SpanID(1)).hex, "0000000000000001")
        XCTAssertEqual(try XCTUnwrap(TraceID(high: 0, low: 255)).hex, "000000000000000000000000000000ff")
        XCTAssertNil(TraceID(high: 0, low: 0))
        XCTAssertNil(SpanID(0))
    }

    func testDecodingRejectsZeroIDs() throws {
        XCTAssertThrowsError(try JSONDecoder().decode(TraceID.self, from: Data(#"{"high":0,"low":0}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(SpanID.self, from: Data(#"{"value":0}"#.utf8)))
        let id = try XCTUnwrap(TraceID(high: 1, low: 2))
        XCTAssertEqual(try JSONDecoder().decode(TraceID.self, from: JSONEncoder().encode(id)), id)
    }

    func testSeededIDsAreReproducibleAcrossInstancesAndSeedSensitive() {
        let a = SeededIDSource(seed: 7), b = SeededIDSource(seed: 7), c = SeededIDSource(seed: 8)
        let sa = (0..<5).map { _ in a.nextTraceID() }
        let sb = (0..<5).map { _ in b.nextTraceID() }
        let sc = (0..<5).map { _ in c.nextTraceID() }
        XCTAssertEqual(sa, sb)
        XCTAssertNotEqual(sa, sc)
        XCTAssertEqual(Set(sa).count, 5)
    }
}

final class SaturatingTests: XCTestCase {
    func testDoubleConversionsNeverTrap() {
        XCTAssertEqual(Saturating.int64(.nan), 0)
        XCTAssertEqual(Saturating.int64(.infinity), .max)
        XCTAssertEqual(Saturating.int64(-.infinity), .min)
        XCTAssertEqual(Saturating.int64(9.3e18), .max)
        XCTAssertEqual(Saturating.int64(-1.5), -1)
        XCTAssertEqual(Saturating.uint64(-3), 0)
        XCTAssertEqual(Saturating.uint64(.nan), 0)
        XCTAssertEqual(Saturating.uint64(1e30), .max)
    }

    func testIntegerOpsClamp() {
        XCTAssertEqual(Saturating.add(Int64.max, 1), .max)
        XCTAssertEqual(Saturating.add(Int64.min, -1), .min)
        XCTAssertEqual(Saturating.subtract(Int64.min, 1), .min)
        XCTAssertEqual(Saturating.subtract(Int64.max, -1), .max)
        XCTAssertEqual(Saturating.multiply(Int64.max, 2), .max)
        XCTAssertEqual(Saturating.multiply(Int64.max, -2), .min)
        XCTAssertEqual(Saturating.subtract(UInt64(3), 5), 0)
        XCTAssertEqual(Saturating.multiply(UInt64.max, 2), .max)
        XCTAssertEqual(Saturating.signed(UInt64.max), .max)
        XCTAssertEqual(Saturating.unsigned(-5), 0)
        XCTAssertEqual(Saturating.int(UInt64.max), Int.max)
    }
}

final class SHA256Tests: XCTestCase {
    func testNISTVectors() {
        XCTAssertEqual(SHA256.hex(SHA256.hash([])),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256.hex(SHA256.hash(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256.hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testHMACRFC4231Vectors() {
        XCTAssertEqual(SHA256.hex(SHA256.hmac(key: [UInt8](repeating: 0x0b, count: 20), message: Array("Hi There".utf8))),
                       "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        XCTAssertEqual(SHA256.hex(SHA256.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        // Key longer than the block size is hashed first.
        XCTAssertEqual(SHA256.hex(SHA256.hmac(key: [UInt8](repeating: 0xaa, count: 131),
                                              message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))),
                       "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    func testHmacHexPrefixIsClamped() {
        XCTAssertEqual(SHA256.hmacHex(key: [1], message: [2], prefixBytes: 0).count, 2)
        XCTAssertEqual(SHA256.hmacHex(key: [1], message: [2], prefixBytes: 99).count, 64)
    }
}

final class ClockSkewTests: XCTestCase {
    let ms: Int64 = 1_000_000

    /// Device clock ahead by `skew`; symmetric `oneWay` delay; server takes `work`.
    func sample(skew: Int64, up: Int64, down: Int64, work: Int64, at mono: UInt64 = 10_000_000_000) -> ClockSample {
        let trueSend: Int64 = 1_800_000_000_000_000_000
        let deviceSend = trueSend + skew
        let serverRecv = trueSend + up
        let serverSend = serverRecv + work
        let rtt = UInt64(up + work + down)
        return ClockSample(clientSendWall: deviceSend, clientSendMono: mono, clientReceiveMono: mono + rtt,
                           serverReceiveWall: serverRecv, serverSendWall: serverSend)
    }

    func testSymmetricDelayGivesTheExactOffset() throws {
        var e = ClockSkewEstimator()
        XCTAssertTrue(e.add(sample(skew: 2_400 * ms, up: 60 * ms, down: 60 * ms, work: 800 * ms)))
        let est = try XCTUnwrap(e.estimate(nowMono: 12_000_000_000))
        let s = sample(skew: 2_400 * ms, up: 60 * ms, down: 60 * ms, work: 800 * ms)
        XCTAssertEqual(s.offsetNanos, -2_400 * ms)
        // Applied to a wall reading taken at the sample's send time.
        XCTAssertEqual(est.offset(fromDeviceWall: s.clientSendWall, atMono: s.clientSendMono), -2_400 * ms)
        XCTAssertEqual(est.uncertaintyNanos, 60 * ms)
    }

    func testLowestDelaySampleWins() throws {
        var e = ClockSkewEstimator()
        // Asymmetric, slow sample: error of (up - down)/2 = 400 ms.
        e.add(sample(skew: 1_000 * ms, up: 900 * ms, down: 100 * ms, work: 10 * ms))
        // Fast, symmetric sample: exact.
        e.add(sample(skew: 1_000 * ms, up: 20 * ms, down: 20 * ms, work: 10 * ms))
        e.add(sample(skew: 1_000 * ms, up: 500 * ms, down: 50 * ms, work: 10 * ms))
        let est = try XCTUnwrap(e.estimate(nowMono: 12_000_000_000))
        let ref = sample(skew: 1_000 * ms, up: 20 * ms, down: 20 * ms, work: 10 * ms)
        XCTAssertEqual(est.offset(fromDeviceWall: ref.clientSendWall, atMono: ref.clientSendMono), -1_000 * ms)
        XCTAssertEqual(est.uncertaintyNanos, 20 * ms)
    }

    func testInconsistentAndImplausibleSamplesAreRejected() {
        var e = ClockSkewEstimator()
        // Server claims it worked longer than the whole round trip.
        let impossible = ClockSample(clientSendWall: 0, clientSendMono: 100, clientReceiveMono: 200,
                                     serverReceiveWall: 0, serverSendWall: 1_000)
        XCTAssertFalse(e.add(impossible))
        // Server send before receive.
        XCTAssertFalse(e.add(ClockSample(clientSendWall: 0, clientSendMono: 0, clientReceiveMono: 1_000,
                                         serverReceiveWall: 10, serverSendWall: 5)))
        // Two days of skew: a broken header, not a clock.
        XCTAssertFalse(e.add(sample(skew: 172_800_000 * ms, up: ms, down: ms, work: ms)))
        XCTAssertEqual(e.rejectedSamples, 3)
        XCTAssertNil(e.estimate(nowMono: 10_000_000_000))
    }

    /// Equal delays: the newest sample must win, so a clock change is picked
    /// up by the next exchange instead of waiting for old samples to expire.
    func testOnATieTheNewestSampleWins() throws {
        var e = ClockSkewEstimator()
        e.add(sample(skew: 2_400 * ms, up: 60 * ms, down: 60 * ms, work: 10 * ms, at: 1_000))
        // The server's clock moved (or ours did on the monotonic axis: a reboot is out of scope).
        let newer = ClockSample(clientSendWall: 0, clientSendMono: 2_000_000_000, clientReceiveMono: 2_130_000_000,
                                serverReceiveWall: 9_000_000_000, serverSendWall: 9_010_000_000)
        e.add(newer)
        let est = try XCTUnwrap(e.estimate(nowMono: 3_000_000_000))
        XCTAssertEqual(est.serverMinusMonoNanos, newer.serverMinusMonoNanos)
    }

    func testOldSamplesExpireAndCapacityIsBounded() {
        var e = ClockSkewEstimator(capacity: 3, maxAgeNanos: 1_000_000_000)
        for i in 0..<10 { e.add(sample(skew: 0, up: ms, down: ms, work: ms, at: UInt64(i) * 1_000)) }
        XCTAssertEqual(e.samples.count, 3)
        XCTAssertNotNil(e.estimate(nowMono: 500_000_000))
        XCTAssertNil(e.estimate(nowMono: 5_000_000_000))
    }

    /// The skew estimate is "server time minus this clock", so the clock must
    /// keep counting through device sleep. CI cannot suspend a machine, so
    /// this pins the *source*: SystemClock must track the boot-time clock.
    func testSystemClockIsTheSleepInclusiveClock() {
        #if canImport(Glibc)
        var ts = timespec()
        XCTAssertEqual(clock_gettime(CLOCK_BOOTTIME, &ts), 0)
        let boot = UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
        let ours = SystemClock().monotonicNanos
        XCTAssertLessThan(ours > boot ? ours - boot : boot - ours, 1_000_000_000)
        #elseif canImport(Darwin)
        let mono = clock_gettime_nsec_np(CLOCK_MONOTONIC)
        let ours = SystemClock().monotonicNanos
        XCTAssertLessThan(ours > mono ? ours - mono : mono - ours, 1_000_000_000)
        #endif
        let a = SystemClock().monotonicNanos
        let b = SystemClock().monotonicNanos
        XCTAssertGreaterThanOrEqual(b, a)
    }

    func testExtremeTimestampsDoNotTrap() throws {
        var e = ClockSkewEstimator(maxPlausibleOffsetNanos: .max)
        let s = ClockSample(clientSendWall: .min, clientSendMono: 0, clientReceiveMono: .max,
                            serverReceiveWall: .max, serverSendWall: .max)
        // RTT saturates at Int64.max; server time is 0; so delay = Int64.max.
        XCTAssertEqual(s.delayNanos, .max)
        // (max - min)/2 halves first, then adds: clamps instead of wrapping.
        XCTAssertEqual(s.offsetNanos, .max)
        XCTAssertTrue(e.add(s))
        let est = try XCTUnwrap(e.estimate(nowMono: .max))
        XCTAssertEqual(est.uncertaintyNanos, Int64.max / 2)
        XCTAssertEqual(est.offset(fromDeviceWall: .min, atMono: .max), .max)
    }
}
