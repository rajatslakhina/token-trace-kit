import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The two clocks a trace needs. Durations come only from the monotonic clock,
/// which cannot jump. The wall clock is read once per trace, as an anchor.
public protocol TraceClock: Sendable {
    /// Nanoseconds from an arbitrary origin; never goes backwards, and
    /// **keeps counting while the device sleeps**. Clock-skew correction is
    /// stored as "server time minus this clock", so a clock that pauses
    /// during sleep (`DispatchTime`, `mach_absolute_time`, Linux
    /// `CLOCK_MONOTONIC`) would make every span exported after a screen lock
    /// land in the past by the length of the sleep.
    var monotonicNanos: UInt64 { get }
    /// Unix-epoch nanoseconds according to this device. May be wrong by seconds.
    var wallNanos: Int64 { get }
}

public struct SystemClock: TraceClock {
    public init() {}
    /// Darwin `CLOCK_MONOTONIC` (which, unlike `CLOCK_UPTIME_RAW` and
    /// `DispatchTime`, includes sleep) or Linux `CLOCK_BOOTTIME`.
    public var monotonicNanos: UInt64 { Self.sleepInclusiveNanos() }

    public static func sleepInclusiveNanos() -> UInt64 {
        #if canImport(Darwin)
        return clock_gettime_nsec_np(CLOCK_MONOTONIC)
        #elseif canImport(Glibc)
        var ts = timespec()
        guard clock_gettime(CLOCK_BOOTTIME, &ts) == 0 else { return DispatchTime.now().uptimeNanoseconds }
        return Saturating.add(Saturating.multiply(Saturating.unsigned(Int64(ts.tv_sec)), 1_000_000_000),
                              Saturating.unsigned(Int64(ts.tv_nsec)))
        #else
        return DispatchTime.now().uptimeNanoseconds
        #endif
    }
    public var wallNanos: Int64 {
        Saturating.int64(Date().timeIntervalSince1970 * 1_000_000_000)
    }
}

/// A clock you move by hand. Used by tests and by the demo's virtual-time runs.
public final class ManualClock: TraceClock, @unchecked Sendable {
    // @unchecked: both fields are only touched while `lock` is held.
    private let lock = NSLock()
    private var mono: UInt64
    private var wall: Int64

    public init(monotonicNanos: UInt64 = 1_000_000_000, wallNanos: Int64 = 1_792_000_000_000_000_000) {
        mono = monotonicNanos
        wall = wallNanos
    }

    public var monotonicNanos: UInt64 { lock.lock(); defer { lock.unlock() }; return mono }
    public var wallNanos: Int64 { lock.lock(); defer { lock.unlock() }; return wall }

    public func advance(nanos: UInt64) {
        lock.lock(); defer { lock.unlock() }
        mono = Saturating.add(mono, nanos)
        wall = Saturating.add(wall, Saturating.signed(nanos))
    }

    public func advance(millis: UInt64) { advance(nanos: Saturating.multiply(millis, 1_000_000)) }

    /// Moves only the wall clock, as NTP or the user changing the time would.
    public func jumpWall(byNanos delta: Int64) {
        lock.lock(); defer { lock.unlock() }
        wall = Saturating.add(wall, delta)
    }
}

/// One request/response exchange with a server that reports when it received
/// the request and when it sent the response (for example through a
/// `Server-Timing` header). The NTP four-timestamp method.
public struct ClockSample: Sendable, Hashable {
    public let clientSendWall: Int64
    public let clientSendMono: UInt64
    public let clientReceiveMono: UInt64
    public let serverReceiveWall: Int64
    public let serverSendWall: Int64

    public init(clientSendWall: Int64, clientSendMono: UInt64, clientReceiveMono: UInt64,
                serverReceiveWall: Int64, serverSendWall: Int64) {
        self.clientSendWall = clientSendWall
        self.clientSendMono = clientSendMono
        self.clientReceiveMono = clientReceiveMono
        self.serverReceiveWall = serverReceiveWall
        self.serverSendWall = serverSendWall
    }

    /// Network round trip excluding server time (δ). Negative means the
    /// sample is inconsistent and must be discarded.
    public var delayNanos: Int64 {
        let rtt = Saturating.signed(Saturating.subtract(clientReceiveMono, clientSendMono))
        return Saturating.subtract(rtt, Saturating.subtract(serverSendWall, serverReceiveWall))
    }

    /// Server time at the midpoint of the exchange minus the client's
    /// monotonic time at the midpoint. Independent of the device wall clock.
    public var serverMinusMonoNanos: Int64 {
        let serverMid = Saturating.add(serverReceiveWall, Saturating.subtract(serverSendWall, serverReceiveWall) / 2)
        let monoMid = Saturating.add(clientSendMono, Saturating.subtract(clientReceiveMono, clientSendMono) / 2)
        return Saturating.subtract(serverMid, Saturating.signed(monoMid))
    }

    /// server clock − client wall clock at the time of the sample (θ). True
    /// offset lies within ±δ/2 of this. Used for the plausibility check; the
    /// pipeline applies ``serverMinusMonoNanos`` instead.
    public var offsetNanos: Int64 {
        // t3 is derived from the monotonic clock, so a wall-clock jump on the
        // device between send and receive cannot corrupt the sample.
        let rtt = Saturating.signed(Saturating.subtract(clientReceiveMono, clientSendMono))
        let t0 = clientSendWall
        let t3 = Saturating.add(t0, rtt)
        let a = Saturating.subtract(serverReceiveWall, t0)
        let b = Saturating.subtract(serverSendWall, t3)
        // (a + b) / 2 without overflowing: halve first, then add the carried bit.
        // `a % 2 + b % 2` is in -2...2, so it cannot overflow.
        return Saturating.add(Saturating.add(a / 2, b / 2), (a % 2 + b % 2) / 2)
    }
}

public struct SkewEstimate: Sendable, Hashable {
    /// Server time minus this device's **monotonic** clock.
    ///
    /// Anchoring to the monotonic clock, not the device wall clock, is what
    /// makes the estimate survive a wall-clock change (NTP, the user, a time
    /// zone bug) between the sample and the trace it is applied to.
    public let serverMinusMonoNanos: Int64
    /// Half the network delay of the sample used: the honest error bar.
    public let uncertaintyNanos: Int64

    /// The correction to add to a device wall time that was read at
    /// monotonic time `mono`, to express it in server time.
    public func offset(fromDeviceWall wall: Int64, atMono mono: UInt64) -> Int64 {
        Saturating.subtract(serverMinusMonoNanos, Saturating.subtract(wall, Saturating.signed(mono)))
    }
}

/// Estimates how wrong the device clock is, so exported client spans line up
/// with server spans in one backend.
///
/// It keeps the last few samples and trusts the one with the **smallest
/// network delay**: asymmetric queuing inflates the error of a sample by up
/// to half its delay, so the fastest exchange is the most accurate. Samples
/// expire, because device clocks drift and get corrected by NTP.
public struct ClockSkewEstimator: Sendable {
    public let capacity: Int
    public let maxAgeNanos: UInt64
    /// Offsets larger than this are treated as a broken server header.
    public let maxPlausibleOffsetNanos: Int64
    private(set) var samples: [(sample: ClockSample, receivedMono: UInt64)] = []
    public private(set) var rejectedSamples = 0

    public init(capacity: Int = 8,
                maxAgeNanos: UInt64 = 600_000_000_000,
                maxPlausibleOffsetNanos: Int64 = 86_400_000_000_000) {
        self.capacity = max(1, capacity)
        self.maxAgeNanos = maxAgeNanos
        self.maxPlausibleOffsetNanos = max(0, maxPlausibleOffsetNanos)
    }

    /// Returns false (and counts) when the sample is inconsistent or implausible.
    @discardableResult
    public mutating func add(_ s: ClockSample) -> Bool {
        guard s.clientReceiveMono >= s.clientSendMono,
              s.serverSendWall >= s.serverReceiveWall,
              s.delayNanos >= 0 else {
            rejectedSamples += 1
            return false
        }
        let off = s.offsetNanos
        guard off <= maxPlausibleOffsetNanos, off >= -maxPlausibleOffsetNanos else {
            rejectedSamples += 1
            return false
        }
        samples.append((s, s.clientReceiveMono))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        return true
    }

    public func estimate(nowMono: UInt64) -> SkewEstimate? {
        let fresh = samples.filter { Saturating.subtract(nowMono, $0.receivedMono) <= maxAgeNanos }
        // Lowest delay wins; on a tie, the newest sample (reversed + strict <).
        guard let best = fresh.reversed().min(by: { $0.sample.delayNanos < $1.sample.delayNanos }) else { return nil }
        return SkewEstimate(serverMinusMonoNanos: best.sample.serverMinusMonoNanos,
                            uncertaintyNanos: best.sample.delayNanos / 2)
    }
}
