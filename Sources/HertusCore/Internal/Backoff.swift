import Foundation

/// How long to wait before asking again.
///
/// A pure function in its own file because it is the piece most worth testing
/// directly and the piece least worth reading a startup path to find.
public enum Backoff {

    /// Five attempts is roughly half a minute of trying, which is long enough.
    public static let maxAttempts = 5

    static let maxBackoffSeconds: Int64 = 60
    static let jitterFraction = 0.2

    /// 1s, 2s, 4s, 8s, 16s, each jittered by plus or minus 20 percent.
    ///
    /// The jitter is the part that matters. Every device on a network
    /// reconnects at the same moment when it comes back, and an un-jittered
    /// backoff turns one outage into a synchronised stampede against the server
    /// that just recovered.
    ///
    /// - Parameters:
    ///   - attempt: 1-based. Growth is capped so a long retry loop cannot
    ///     strand the SDK for the rest of the session.
    ///   - retryAfterSeconds: the server's own instruction, which wins when
    ///     present and positive. Capped for the same reason.
    ///   - jitter: supplied so a test can pin it. Defaults to a real draw.
    public static func delayMillis(
        attempt: Int,
        retryAfterSeconds: Int64? = nil,
        jitter: (ClosedRange<Int64>) -> Int64 = { Int64.random(in: $0) }
    ) -> Int64 {
        if let retryAfterSeconds, retryAfterSeconds > 0 {
            return min(retryAfterSeconds, maxBackoffSeconds) * 1000
        }

        let exponent = min(max(attempt - 1, 0), 4)
        let base = Int64(1 << exponent) * 1000
        let spread = Int64(Double(base) * jitterFraction)
        return base + jitter(-spread...spread)
    }
}
