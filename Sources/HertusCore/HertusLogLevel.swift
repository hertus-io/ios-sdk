import Foundation

/// How much the SDK says.
///
/// Ordered by severity, so a threshold is a comparison rather than a set. The
/// SDK logs under one subsystem so that filtering shows the whole of its
/// behaviour and nothing else; integration problems are diagnosed from that
/// output far more often than from a debugger.
public enum HertusLogLevel: Int, Comparable, CaseIterable {

    /// The only level permitted to carry text that came from outside this SDK,
    /// and unavailable in `production` whatever the host app asks for. See
    /// `Logger`.
    case verbose = 0

    case debug = 1
    case info = 2
    case warn = 3
    case error = 4

    /// Nothing at all, including errors.
    case suppress = 5

    public static func < (lhs: HertusLogLevel, rhs: HertusLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
