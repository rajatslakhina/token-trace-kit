/// A span attribute value. Deliberately small: no arrays, no nested maps, so
/// every value has an obvious redaction rule and an obvious wire size.
public enum AttributeValue: Hashable, Sendable, Codable, CustomStringConvertible {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)

    public var description: String {
        switch self {
        case .string(let s): return "\"\(s)\""
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        }
    }

    public var intValue: Int64? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Rough encoded size, used to bound the export buffer by bytes.
    var estimatedBytes: Int {
        switch self {
        case .string(let s): return s.utf8.count + 2
        case .int, .double: return 8
        case .bool: return 1
        }
    }
}

/// Well-known attribute keys. The `gen_ai.*` names follow the OpenTelemetry
/// GenAI semantic conventions so a vendor's exported spans and ours line up in
/// one backend.
public enum AttributeKey {
    public static let feature = "app.feature"
    public static let tier = "app.ai.tier"
    public static let userID = "enduser.id"
    public static let fallbackReason = "app.ai.fallback_reason"
    public static let networkType = "network.connection.type"
    public static let httpStatus = "http.response.status_code"
    public static let model = "gen_ai.request.model"
    public static let system = "gen_ai.system"
    public static let inputTokens = "gen_ai.usage.input_tokens"
    public static let outputTokens = "gen_ai.usage.output_tokens"
    public static let cacheReadTokens = "gen_ai.usage.cache_read_input_tokens"
    public static let promptLengthBucket = "app.ai.prompt.length_bucket"
    public static let promptDigest = "app.ai.prompt.digest"
    /// Free text from an error path. Scanned, because servers echo user input.
    public static let errorMessage = "app.error.message"
    public static let attempt = "app.http.attempt"
}

public enum SpanKind: String, Sendable, Codable, CaseIterable {
    /// A user interaction (tap, submit). Usually the root.
    case interaction
    /// Work inside the app process, such as an on-device model call.
    case `internal`
    /// An outbound request; its id is what goes into `traceparent`.
    case client
    /// Work done by a server on behalf of a client span.
    case server
}

/// Span outcome. The AI-specific cases matter for sampling: a refusal or a
/// fallback is "the feature did not do what the user asked", which is exactly
/// what you need to be able to debug, even when nothing threw.
public enum SpanStatus: Hashable, Sendable, Codable, CustomStringConvertible {
    case unset
    case ok
    case error(code: String)
    case refused
    case fallback(reason: String)
    /// Force-ended by the tracer because the trace timed out.
    case abandoned

    public var description: String {
        switch self {
        case .unset: return "unset"
        case .ok: return "ok"
        case .error(let c): return "error(\(c))"
        case .refused: return "refused"
        case .fallback(let r): return "fallback(\(r))"
        case .abandoned: return "abandoned"
        }
    }

    /// A status that forces a trace to be kept regardless of sampling ratio.
    public var isNotable: Bool {
        switch self {
        case .unset, .ok: return false
        case .error, .refused, .fallback, .abandoned: return true
        }
    }
}

/// Text that must never reach an exporter (a prompt, a completion, a note the
/// user typed). String interpolation, `print`, `dump` and debuggers all see
/// "<redacted>", and the only ways to turn it into an attribute are the two
/// lossy projections below.
public struct SensitiveText: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let value: String

    public init(_ value: String) { self.value = value }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }

    /// Coarse length bucket. Exact lengths can fingerprint short inputs.
    public var lengthBucket: String {
        let n = value.count
        switch n {
        case 0: return "0"
        case 1...63: return "1-63"
        case 64...255: return "64-255"
        case 256...1023: return "256-1023"
        case 1024...4095: return "1024-4095"
        default: return "4096+"
        }
    }

    /// Keyed digest (HMAC-SHA256, truncated). Lets you see "the same prompt
    /// failed 40 times" without exporting the prompt.
    public func digest(key: [UInt8]) -> String {
        SHA256.hmacHex(key: key, message: Array(value.utf8), prefixBytes: 8)
    }
}
