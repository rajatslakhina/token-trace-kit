/// Arithmetic that clamps instead of trapping.
///
/// Telemetry code runs on every user interaction and consumes values that come
/// from other machines (server timestamps, token counts in a response). A
/// malformed header must never be able to crash the app through `+`, `-`, `*`
/// or `Int(someDouble)`, so every such operation in this package goes through
/// these helpers.
public enum Saturating {
    public static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.addingReportingOverflow(b)
        if !o { return r }
        return b > 0 ? .max : .min
    }

    public static func subtract(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.subtractingReportingOverflow(b)
        if !o { return r }
        return b < 0 ? .max : .min
    }

    public static func multiply(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        if !o { return r }
        return (a < 0) == (b < 0) ? .max : .min
    }

    public static func add(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (r, o) = a.addingReportingOverflow(b)
        return o ? .max : r
    }

    /// `a - b`, floored at zero.
    public static func subtract(_ a: UInt64, _ b: UInt64) -> UInt64 {
        a > b ? a - b : 0
    }

    public static func multiply(_ a: UInt64, _ b: UInt64) -> UInt64 {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        return o ? .max : r
    }

    /// Converts a signed value to `UInt64`, clamping negatives to zero.
    public static func unsigned(_ v: Int64) -> UInt64 {
        v <= 0 ? 0 : UInt64(v)
    }

    /// Converts to `Int64`, clamping values above `Int64.max`.
    public static func signed(_ v: UInt64) -> Int64 {
        v > UInt64(Int64.max) ? .max : Int64(v)
    }

    /// `Int64(d)` without the trap on NaN, infinity or out-of-range input.
    /// NaN maps to `fallback`.
    public static func int64(_ d: Double, fallback: Int64 = 0) -> Int64 {
        guard !d.isNaN else { return fallback }
        // 2^63 is exactly representable as a Double; anything >= it overflows.
        let limit = 9_223_372_036_854_775_808.0
        if d >= limit { return .max }
        if d < -limit { return .min }
        return Int64(d)
    }

    /// `UInt64(d)` without the trap. NaN and negatives map to 0.
    public static func uint64(_ d: Double) -> UInt64 {
        guard !d.isNaN, d > 0 else { return 0 }
        let limit = 18_446_744_073_709_551_616.0 // 2^64
        if d >= limit { return .max }
        return UInt64(d)
    }

    /// `Int(v)` for a `UInt64`, clamped to the platform's `Int.max`
    /// (32-bit on watchOS, so the ceiling is derived, never hardcoded).
    public static func int(_ v: UInt64) -> Int {
        v > UInt64(Int.max) ? Int.max : Int(v)
    }

    /// `Int(v)` for an `Int64`, clamped to the platform's `Int` range.
    public static func int(_ v: Int64) -> Int {
        if v > Int64(Int.max) { return .max }
        if v < Int64(Int.min) { return .min }
        return Int(v)
    }
}
