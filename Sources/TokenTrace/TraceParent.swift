/// The W3C `traceparent` header: `version-traceid-parentid-flags`.
///
/// Parsing is strict on purpose. A value this app did not mint arrives from a
/// push payload, a deep link or a server response, and an invalid one must be
/// discarded (start a new trace) rather than "fixed", because a repaired id
/// silently joins two unrelated traces.
public struct TraceParent: Hashable, Sendable {
    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        /// The caller recorded, or may record, this trace.
        public static let sampled = Flags(rawValue: 0x01)
        /// Level 2: the rightmost 7 bytes of the trace-id are random.
        public static let random = Flags(rawValue: 0x02)
        /// The only bits this implementation understands and re-emits.
        public static let known: Flags = [.sampled, .random]
    }

    public let traceID: TraceID
    public let parentID: SpanID
    public let flags: Flags

    public init(traceID: TraceID, parentID: SpanID, flags: Flags) {
        self.traceID = traceID
        self.parentID = parentID
        // Unknown flag bits must not be propagated.
        self.flags = flags.intersection(.known)
    }

    /// Version 00 header value. Always 55 characters.
    public var headerValue: String {
        "00-\(traceID.hex)-\(parentID.hex)-\(HexCodec.format8(flags.rawValue))"
    }

    /// Parses a header value. Returns nil for anything invalid, including
    /// version `ff`, all-zero ids, uppercase hex and a version-00 value with
    /// trailing data. A higher (future) version is accepted if its first 55
    /// characters parse and any extra data starts with `-`, as the spec asks.
    public static func parse(_ raw: String) -> TraceParent? {
        let value = raw.trimmingWhitespace()
        let utf8 = Array(value.utf8)
        guard utf8.count >= 55, utf8.count <= 512 else { return nil }
        // ASCII only, so every byte offset below is also a character boundary.
        guard utf8.allSatisfy({ $0 < 0x80 }) else { return nil }
        let dash = UInt8(ascii: "-")
        guard utf8[2] == dash, utf8[35] == dash, utf8[52] == dash else { return nil }

        let s = Substring(value)
        func slice(_ from: Int, _ len: Int) -> Substring {
            let a = s.utf8.index(s.utf8.startIndex, offsetBy: from)
            let b = s.utf8.index(a, offsetBy: len)
            return Substring(s.utf8[a..<b])
        }
        guard let version = HexCodec.parse64(slice(0, 2)), version != 0xFF else { return nil }
        if version == 0 {
            guard utf8.count == 55 else { return nil }
        } else if utf8.count > 55 {
            guard utf8[55] == dash else { return nil }
        }
        guard let trace = TraceID(hex: slice(3, 32)),
              let parent = SpanID(hex: slice(36, 16)),
              let rawFlags = HexCodec.parse64(slice(53, 2)) else { return nil }
        // rawFlags came from exactly two hex digits, so it is at most 0xFF.
        return TraceParent(traceID: trace, parentID: parent, flags: Flags(rawValue: UInt8(rawFlags)))
    }
}

extension String {
    func trimmingWhitespace() -> String {
        var scalars = Substring(self).unicodeScalars
        while let f = scalars.first, f == " " || f == "\t" { scalars.removeFirst() }
        while let l = scalars.last, l == " " || l == "\t" { scalars.removeLast() }
        return String(scalars)
    }
}
