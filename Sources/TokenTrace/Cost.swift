/// Money as integer pico-dollars (10⁻¹² USD).
///
/// Token prices are quoted per million tokens, so tokens × (micro-dollars per
/// million tokens) is exactly pico-dollars, with no division and no floating
/// point. A cheap tier's single call costs fractions of a micro-dollar; in
/// `Double` dollars, summing millions of them drifts. Int64 pico-dollars
/// tops out near $9.2 million, far above any per-device total, and every
/// operation saturates rather than traps.
public enum Money {
    public static let picoPerDollar: Int64 = 1_000_000_000_000

    /// "$0.00031250" style: up to 8 decimals, trailing zeros trimmed to 2.
    /// Integer-only, so it is exact and locale-independent.
    public static func format(picoDollars p: Int64) -> String {
        let sign = p < 0 ? "-" : ""
        let mag = p.magnitude
        let per = UInt64(picoPerDollar)
        let whole = mag / per
        // 12 fractional digits, keep the first 8 (rounded down: 10^-8 USD).
        var frac = String(mag % per)
        frac = String(repeating: "0", count: max(0, 12 - frac.count)) + frac
        var shown = String(frac.prefix(8))
        while shown.count > 2 && shown.hasSuffix("0") { shown.removeLast() }
        return sign + "$" + String(whole) + "." + shown
    }
}

public struct ModelPrice: Sendable, Hashable, Codable {
    public var inputMicrosPerMTok: Int64
    public var outputMicrosPerMTok: Int64
    public var cacheReadMicrosPerMTok: Int64

    public init(inputMicrosPerMTok: Int64, outputMicrosPerMTok: Int64, cacheReadMicrosPerMTok: Int64) {
        self.inputMicrosPerMTok = max(0, inputMicrosPerMTok)
        self.outputMicrosPerMTok = max(0, outputMicrosPerMTok)
        self.cacheReadMicrosPerMTok = max(0, cacheReadMicrosPerMTok)
    }

    public func cost(input: Int64, output: Int64, cacheRead: Int64) -> Int64 {
        let i = Saturating.multiply(max(0, input), inputMicrosPerMTok)
        let o = Saturating.multiply(max(0, output), outputMicrosPerMTok)
        let c = Saturating.multiply(max(0, cacheRead), cacheReadMicrosPerMTok)
        return Saturating.add(Saturating.add(i, o), c)
    }
}

/// Prices the app ships with. Owned by the app, not this library: prices
/// change, and a price change should be a config change.
public struct PriceTable: Sendable, Hashable {
    public var prices: [String: ModelPrice]
    public init(_ prices: [String: ModelPrice]) { self.prices = prices }

    /// Cost of every priced LLM call in a trace. `unpriced` counts calls whose
    /// model is missing from the table: those are reported, never priced at $0.
    public func cost(of trace: CompletedTrace) -> (picoDollars: Int64, calls: Int, unpriced: Int, tokens: TokenTotals) {
        var total: Int64 = 0
        var calls = 0
        var unpriced = 0
        var tokens = TokenTotals()
        for s in trace.spans {
            let a = s.attributes
            let input = a[AttributeKey.inputTokens]?.intValue
            let output = a[AttributeKey.outputTokens]?.intValue
            guard input != nil || output != nil else { continue }
            let cache = a[AttributeKey.cacheReadTokens]?.intValue ?? 0
            calls += 1
            tokens.input = Saturating.add(tokens.input, max(0, input ?? 0))
            tokens.output = Saturating.add(tokens.output, max(0, output ?? 0))
            tokens.cacheRead = Saturating.add(tokens.cacheRead, max(0, cache))
            guard let model = a[AttributeKey.model]?.stringValue, let p = prices[model] else {
                unpriced += 1
                continue
            }
            total = Saturating.add(total, p.cost(input: input ?? 0, output: output ?? 0, cacheRead: cache))
        }
        return (total, calls, unpriced, tokens)
    }
}

public struct TokenTotals: Sendable, Hashable, Codable {
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var cacheRead: Int64 = 0
    public init() {}
}

/// Per-feature cost and latency, from **every** completed trace.
public struct FeatureCost: Sendable, Hashable {
    public let feature: String
    public let traces: Int
    public let llmCalls: Int
    public let unpricedCalls: Int
    public let tokens: TokenTotals
    public let picoDollars: Int64
    public let p50Nanos: UInt64
    public let p95Nanos: UInt64
    public let fallbackTraces: Int

    public var costPerTracePicoDollars: Int64 { traces > 0 ? picoDollars / Int64(traces) : 0 }
}

/// Rolls up cost and latency by `app.feature`.
///
/// It runs **before** sampling. Sampling decides which traces you can debug;
/// it must never decide what you think a feature costs. If cost were computed
/// from exported traces, a 5% keep ratio plus "always keep errors" would
/// overweight failures by an order of magnitude, and the bill would not match.
public struct CostAttributor: Sendable {
    struct Bucket: Sendable {
        var traces = 0
        var calls = 0
        var unpriced = 0
        var tokens = TokenTotals()
        var pico: Int64 = 0
        var fallbacks = 0
        /// Most recent durations, bounded.
        var durations: [UInt64] = []
    }

    public let prices: PriceTable
    public let maxFeatures: Int
    public let latencyWindow: Int
    private var buckets: [String: Bucket] = [:]
    public static let overflowFeature = "(other)"

    public init(prices: PriceTable, maxFeatures: Int = 32, latencyWindow: Int = 256) {
        self.prices = prices
        self.maxFeatures = max(1, maxFeatures)
        self.latencyWindow = max(1, latencyWindow)
    }

    /// Records a trace and returns its cost, so the sampler can use it.
    @discardableResult
    public mutating func record(_ trace: CompletedTrace) -> Int64 {
        let c = prices.cost(of: trace)
        var key = trace.feature
        if buckets[key] == nil && buckets.count >= maxFeatures { key = Self.overflowFeature }
        var b = buckets[key] ?? Bucket()
        b.traces += 1
        b.calls += c.calls
        b.unpriced += c.unpriced
        b.tokens.input = Saturating.add(b.tokens.input, c.tokens.input)
        b.tokens.output = Saturating.add(b.tokens.output, c.tokens.output)
        b.tokens.cacheRead = Saturating.add(b.tokens.cacheRead, c.tokens.cacheRead)
        b.pico = Saturating.add(b.pico, c.picoDollars)
        if trace.spans.contains(where: { if case .fallback = $0.status { return true } else { return false } }) {
            b.fallbacks += 1
        }
        b.durations.append(trace.rootDurationNanos)
        if b.durations.count > latencyWindow { b.durations.removeFirst(b.durations.count - latencyWindow) }
        buckets[key] = b
        return c.picoDollars
    }

    public func report() -> [FeatureCost] {
        buckets.map { name, b in
            let sorted = b.durations.sorted()
            return FeatureCost(feature: name, traces: b.traces, llmCalls: b.calls, unpricedCalls: b.unpriced,
                               tokens: b.tokens, picoDollars: b.pico,
                               p50Nanos: Self.percentile(sorted, 50), p95Nanos: Self.percentile(sorted, 95),
                               fallbackTraces: b.fallbacks)
        }.sorted { $0.feature < $1.feature }
    }

    /// Nearest-rank percentile of an ascending array; 0 for an empty one.
    public static func percentile(_ sorted: [UInt64], _ p: Int) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let pc = min(100, max(0, p))
        // rank = ceil(p/100 * n), in 1...n; computed in integers.
        // Split n = 100q + r so nothing overflows even where Int is 32-bit.
        let n = sorted.count
        let rank = max(1, (n / 100) * pc + ((n % 100) * pc + 99) / 100)
        let i = min(sorted.count - 1, rank - 1)
        return sorted[i]
    }
}
