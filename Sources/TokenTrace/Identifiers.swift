import Foundation

/// A W3C Trace Context trace-id: 16 bytes, never all zero.
public struct TraceID: Hashable, Sendable, Comparable, CustomStringConvertible, Codable {
    public let high: UInt64
    public let low: UInt64

    /// Returns nil for the all-zero id, which W3C reserves as invalid.
    public init?(high: UInt64, low: UInt64) {
        guard high != 0 || low != 0 else { return nil }
        self.high = high
        self.low = low
    }

    /// Parses exactly 32 lowercase hex characters. Uppercase is rejected, as the
    /// spec requires: a receiver must not "repair" an id it did not issue.
    public init?(hex: Substring) {
        guard hex.utf8.count == 32,
              let h = HexCodec.parse64(hex.prefix(16)),
              let l = HexCodec.parse64(hex.suffix(16)) else { return nil }
        self.init(high: h, low: l)
    }

    public init?(hex: String) { self.init(hex: Substring(hex)) }

    public var hex: String { HexCodec.format64(high) + HexCodec.format64(low) }
    public var description: String { hex }

    /// The rightmost 7 bytes (56 bits). With W3C Trace Context Level 2's
    /// "random" flag set, these bits are uniformly random, so every tier that
    /// sees the same trace-id makes the same ratio-sampling decision with no
    /// coordination. See ``TailSampler``.
    public var randomness56: UInt64 { low & 0x00FF_FFFF_FFFF_FFFF }

    private enum CodingKeys: String, CodingKey { case high, low }

    /// Decoding enforces the same non-zero rule as `init?(high:low:)`, so a
    /// corrupted snapshot cannot smuggle in the invalid all-zero id.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let h = try c.decode(UInt64.self, forKey: .high)
        let l = try c.decode(UInt64.self, forKey: .low)
        guard h != 0 || l != 0 else {
            throw DecodingError.dataCorruptedError(forKey: .low, in: c, debugDescription: "all-zero trace-id")
        }
        high = h
        low = l
    }

    public static func < (a: TraceID, b: TraceID) -> Bool {
        (a.high, a.low) < (b.high, b.low)
    }
}

/// A W3C Trace Context parent-id / span-id: 8 bytes, never zero.
public struct SpanID: Hashable, Sendable, CustomStringConvertible, Codable {
    public let value: UInt64

    public init?(_ value: UInt64) {
        guard value != 0 else { return nil }
        self.value = value
    }

    public init?(hex: Substring) {
        guard hex.utf8.count == 16, let v = HexCodec.parse64(hex) else { return nil }
        self.init(v)
    }

    public init?(hex: String) { self.init(hex: Substring(hex)) }

    public var hex: String { HexCodec.format64(value) }
    public var description: String { hex }

    private enum CodingKeys: String, CodingKey { case value }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(UInt64.self, forKey: .value)
        guard v != 0 else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: c, debugDescription: "zero span-id")
        }
        value = v
    }
}

enum HexCodec {
    /// Strict lowercase hex, at most 16 digits.
    static func parse64(_ s: Substring) -> UInt64? {
        guard !s.isEmpty, s.utf8.count <= 16 else { return nil }
        var v: UInt64 = 0
        for b in s.utf8 {
            let d: UInt8
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = b - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = b - UInt8(ascii: "a") + 10
            default: return nil
            }
            // At most 16 digits, so this shift never loses bits that matter.
            v = (v << 4) | UInt64(d)
        }
        return v
    }

    static func format64(_ v: UInt64) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8](repeating: UInt8(ascii: "0"), count: 16)
        var x = v
        var i = 15
        while i >= 0 {
            // `x & 0xF` is always in 0...15, a valid index into the 16 digits.
            out[i] = digits[Int(x & 0xF)]
            x >>= 4
            i -= 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func format8(_ v: UInt8) -> String {
        String(format64(UInt64(v)).suffix(2))
    }
}

/// Where new ids come from. Injected so tests and the demo are deterministic.
public protocol IDSource: Sendable {
    func nextTraceID() -> TraceID
    func nextSpanID() -> SpanID
}

/// Production ids from the system CSPRNG.
public struct RandomIDSource: IDSource {
    public init() {}

    public func nextTraceID() -> TraceID {
        var g = SystemRandomNumberGenerator()
        while true {
            if let id = TraceID(high: g.next(), low: g.next()) { return id }
        }
    }

    public func nextSpanID() -> SpanID {
        var g = SystemRandomNumberGenerator()
        while true {
            if let id = SpanID(g.next()) { return id }
        }
    }
}

/// Deterministic ids (SplitMix64) for tests and the demo's replayable runs.
public final class SeededIDSource: IDSource, @unchecked Sendable {
    // @unchecked: `state` is only touched while `lock` is held.
    private let lock = NSLock()
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    private func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public func nextTraceID() -> TraceID {
        while true {
            if let id = TraceID(high: next(), low: next()) { return id }
        }
    }

    public func nextSpanID() -> SpanID {
        while true {
            if let id = SpanID(next()) { return id }
        }
    }
}
