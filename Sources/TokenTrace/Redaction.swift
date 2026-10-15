import Foundation

/// How one attribute may leave the device.
public enum PrivacyClass: Hashable, Sendable {
    /// Exported as is. For values that are never personal (token counts, model ids).
    case allow
    /// Strings are scanned and emails, card numbers and phone numbers replaced.
    /// Non-strings pass through.
    case scan
    /// Replaced with a keyed digest: correlatable within one install, not
    /// reversible, and not joinable across installs without the key.
    case hash
    /// Never exported.
    case drop
}

/// Default-deny attribute policy.
///
/// The failure this exists to prevent is not a malicious engineer; it is a
/// well-meaning one adding `span.setAttribute("prompt", text)` while
/// debugging. With an allowlist, a key nobody classified is dropped and
/// counted, so the mistake shows up as a metric instead of in a vendor's
/// trace store. Exact keys win over prefixes; the longest prefix wins.
public struct AttributePolicy: Sendable, Hashable {
    public var exact: [String: PrivacyClass]
    public var prefixes: [String: PrivacyClass]
    public var unclassified: PrivacyClass

    public init(exact: [String: PrivacyClass] = [:], prefixes: [String: PrivacyClass] = [:],
                unclassified: PrivacyClass = .drop) {
        self.exact = exact
        self.prefixes = prefixes
        self.unclassified = unclassified
    }

    public func classify(_ key: String) -> PrivacyClass {
        if let c = exact[key] { return c }
        var best: (len: Int, cls: PrivacyClass)?
        for (p, c) in prefixes where key.hasPrefix(p) {
            if best == nil || p.count > (best?.len ?? 0) { best = (p.count, c) }
        }
        return best?.cls ?? unclassified
    }

    /// True when an exact or prefix rule covers `key`.
    public func isClassified(_ key: String) -> Bool {
        exact[key] != nil || prefixes.keys.contains { key.hasPrefix($0) }
    }

    /// A reasonable starting point for an AI feature.
    public static let standard = AttributePolicy(
        exact: [
            AttributeKey.feature: .allow,
            AttributeKey.tier: .allow,
            AttributeKey.fallbackReason: .allow,
            AttributeKey.networkType: .allow,
            AttributeKey.httpStatus: .allow,
            AttributeKey.model: .allow,
            AttributeKey.system: .allow,
            AttributeKey.promptLengthBucket: .allow,
            AttributeKey.promptDigest: .allow,
            AttributeKey.userID: .hash,
            AttributeKey.errorMessage: .scan,
            AttributeKey.attempt: .allow
        ],
        prefixes: ["gen_ai.usage.": .allow]
    )
}

/// Finds and masks personal data inside free-text attribute values.
public enum PIIScanner {
    private static let emailPattern = "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
    // Runs of 7+ digits with optional single spaces, dots or dashes between them.
    private static let digitsPattern = "\\+?\\d(?:[ .-]?\\d){6,}"

    public static func scrub(_ s: String) -> String {
        // Compiled per call: this runs only on export, only for `.scan` keys,
        // and keeps a non-Sendable NSRegularExpression out of global state.
        let email = try? NSRegularExpression(pattern: emailPattern)
        let digits = try? NSRegularExpression(pattern: digitsPattern)
        var out = replace(email, in: s) { _ in "[email]" }
        out = replace(digits, in: out) { match in
            let ds = match.filter(\.isNumber).compactMap(\.wholeNumberValue)
            if (13...19).contains(ds.count) && luhn(ds) { return "[card]" }
            return "[phone]"
        }
        return out
    }

    /// Luhn checksum over decimal digits (each 0...9).
    public static func luhn(_ digits: [Int]) -> Bool {
        guard !digits.isEmpty else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            guard (0...9).contains(d) else { return false }
            if i % 2 == 1 {
                let x = d * 2
                sum += x > 9 ? x - 9 : x
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    private static func replace(_ re: NSRegularExpression?, in s: String, with f: (String) -> String) -> String {
        guard let re else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            guard r.location != NSNotFound, r.location >= last, r.location + r.length <= ns.length else { continue }
            result += ns.substring(with: NSRange(location: last, length: r.location - last))
            result += f(ns.substring(with: r))
            last = r.location + r.length
        }
        result += ns.substring(from: last)
        return result
    }
}

public struct RedactionCounters: Sendable, Hashable {
    public var dropped = 0
    public var hashed = 0
    public var scrubbed = 0
    /// Keys dropped only because nobody classified them. A non-zero value is a
    /// code-review signal, not an incident.
    public var unclassifiedKeys: Set<String> = []
}

/// Applies an ``AttributePolicy`` to a span's attributes.
public struct Redactor: Sendable {
    public let policy: AttributePolicy
    private let hashKey: [UInt8]

    /// `hashKey` should be a per-install random secret kept in the keychain.
    public init(policy: AttributePolicy, hashKey: [UInt8]) {
        self.policy = policy
        self.hashKey = hashKey
    }

    public func redact(_ attrs: [String: AttributeValue], counters: inout RedactionCounters) -> [String: AttributeValue] {
        var out: [String: AttributeValue] = [:]
        for (k, v) in attrs {
            switch policy.classify(k) {
            case .allow:
                out[k] = v
            case .scan:
                if case .string(let s) = v {
                    let cleaned = PIIScanner.scrub(s)
                    if cleaned != s { counters.scrubbed += 1 }
                    out[k] = .string(cleaned)
                } else {
                    out[k] = v
                }
            case .hash:
                out[k] = .string(SHA256.hmacHex(key: hashKey, message: Array(v.description.utf8), prefixBytes: 8))
                counters.hashed += 1
            case .drop:
                counters.dropped += 1
                if !policy.isClassified(k) && counters.unclassifiedKeys.count < 64 {
                    counters.unclassifiedKeys.insert(k)
                }
            }
        }
        return out
    }
}
