/// Why a trace was kept.
public enum KeepReason: Hashable, Sendable, Codable, CustomStringConvertible {
    case error
    case refused
    case fallback
    case abandoned
    case slow(durationNanos: UInt64)
    case expensive(picoDollars: Int64)
    case ratio

    public var description: String {
        switch self {
        case .error: return "error"
        case .refused: return "refusal"
        case .fallback: return "fallback"
        case .abandoned: return "abandoned"
        case .slow(let d): return "slow (\(d / 1_000_000) ms)"
        case .expensive(let p): return "expensive (\(Money.format(picoDollars: p)))"
        case .ratio: return "ratio sample"
        }
    }

    /// Forced reasons override the ratio and get export priority.
    public var isForced: Bool { self != .ratio }
}

public enum SamplingDecision: Hashable, Sendable {
    case keep([KeepReason])
    case drop

    public var isKept: Bool { if case .keep = self { return true } else { return false } }
    public var isForced: Bool {
        if case .keep(let r) = self { return r.contains { $0.isForced } }
        return false
    }
}

public struct SamplingPolicy: Sendable, Hashable {
    /// Root duration at or above which a trace is always kept.
    public var latencySLONanos: UInt64
    /// Cost at or above which a trace is always kept. nil disables the rule.
    public var costThresholdPicoDollars: Int64?
    /// Fraction of healthy traces to keep, 0...1. NaN is treated as 0.
    public var healthyKeepRatio: Double

    public init(latencySLONanos: UInt64 = 2_500_000_000, costThresholdPicoDollars: Int64? = nil,
                healthyKeepRatio: Double = 0.05) {
        self.latencySLONanos = latencySLONanos
        self.costThresholdPicoDollars = costThresholdPicoDollars
        self.healthyKeepRatio = healthyKeepRatio
    }

    /// The OpenTelemetry consistent-probability **rejection threshold**
    /// T = (1 − ratio) × 2⁵⁶ over the trace-id's 56 random bits R. A trace is
    /// kept when R ≥ T, the same comparison an OTel probability sampler
    /// configured with the same ratio makes, so the tiers agree on which
    /// healthy traces to keep without coordinating.
    public var rejectionThreshold56: UInt64 {
        let r = healthyKeepRatio.isNaN ? 0 : min(1, max(0, healthyKeepRatio))
        let full: UInt64 = 1 << 56
        if r >= 1 { return 0 }
        // keep-count = r × 2^56, rounded down; T = 2^56 − keep-count.
        return full - min(full, Saturating.uint64(r * Double(full)))
    }

    /// True if a healthy trace with this id is kept by the ratio rule.
    public func ratioKeeps(_ id: TraceID) -> Bool { id.randomness56 >= rejectionThreshold56 }
}

/// Decides, once every span has ended, whether a trace is worth exporting.
///
/// Head sampling (decide at the tap) is cheap but blind: at 5% it throws away
/// 95% of your refusals and timeouts, which are the traces you need. Shipping
/// everything to a collector-side tail sampler is accurate, but it spends the
/// user's battery, data and privacy on traces that will be discarded. The
/// phone is the only place that sees the whole client-side trace, so it
/// decides there: every notable trace is kept, and healthy ones are kept by
/// a ratio that every tier can reproduce from the trace-id alone.
public struct TailSampler: Sendable {
    public let policy: SamplingPolicy

    public init(policy: SamplingPolicy) { self.policy = policy }

    public func decide(_ trace: CompletedTrace, costPicoDollars: Int64?) -> SamplingDecision {
        var reasons: [KeepReason] = []
        func add(_ r: KeepReason) { if !reasons.contains(r) { reasons.append(r) } }
        for s in trace.spans {
            switch s.status {
            case .error: add(.error)
            case .refused: add(.refused)
            case .fallback: add(.fallback)
            case .abandoned: add(.abandoned)
            case .ok, .unset: break
            }
        }
        if trace.reason == .timedOut { add(.abandoned) }
        if trace.rootDurationNanos >= policy.latencySLONanos {
            add(.slow(durationNanos: trace.rootDurationNanos))
        }
        if let limit = policy.costThresholdPicoDollars, let c = costPicoDollars, c >= limit {
            add(.expensive(picoDollars: c))
        }
        if !reasons.isEmpty { return .keep(reasons) }
        return policy.ratioKeeps(trace.traceID) ? .keep([.ratio]) : .drop
    }
}
