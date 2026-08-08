import Foundation

#if canImport(os)
import os
#endif

/// One subsystem, one threshold, and one rule about what may be said.
///
/// The subsystem is fixed at `io.hertus.sdk` so a Console filter shows the whole
/// of the SDK's behaviour and nothing else. Integration problems are diagnosed
/// from this output far more often than from a debugger, so the lines are
/// written to be read in sequence.
public final class Logger {

    public static let subsystem = "io.hertus.sdk"

    /// Where a line goes. Injected so a test can assert on what was said
    /// without a console, and so the default can differ per platform.
    public typealias Sink = (HertusLogLevel, String) -> Void

    /// `verbose` is unavailable in production, whatever the host app asked for.
    ///
    /// It is the only level permitted to carry text that came from outside this
    /// SDK: an engine's own error strings, which name their vendor. Clamping
    /// here rather than at each call site means the guarantee holds for any
    /// future caller that forgets, and it is why the diagnostic channel in
    /// `EngineResultHandler` is safe to exist at all.
    public let threshold: HertusLogLevel

    private let sink: Sink

    public init(
        level: HertusLogLevel,
        environment: HertusEnvironment,
        sink: @escaping Sink = Logger.defaultSink
    ) {
        self.threshold = (environment == .production && level == .verbose) ? .debug : level
        self.sink = sink
    }

    public func v(_ message: @autoclosure () -> String) { at(.verbose, message) }
    public func d(_ message: @autoclosure () -> String) { at(.debug, message) }
    public func i(_ message: @autoclosure () -> String) { at(.info, message) }
    public func w(_ message: @autoclosure () -> String) { at(.warn, message) }
    public func e(_ message: @autoclosure () -> String) { at(.error, message) }

    /// The message is an autoclosure so that a suppressed line costs no string
    /// interpolation. Guard logs on a hot path and most builds discard most of
    /// what it says.
    private func at(_ level: HertusLogLevel, _ message: () -> String) {
        guard threshold != .suppress, level >= threshold else { return }
        sink(level, message())
    }

    /// Unified logging on Apple platforms, stdout everywhere else so the
    /// package stays usable on a host with no `os` module.
    public static let defaultSink: Sink = { level, message in
        #if canImport(os)
        let logger = OSLog(subsystem: Logger.subsystem, category: "sdk")
        os_log("%{public}@", log: logger, type: level.osLogType, message)
        #else
        print("[hertus] \(message)")
        #endif
    }
}

#if canImport(os)
private extension HertusLogLevel {
    var osLogType: OSLogType {
        switch self {
        case .verbose, .debug: return .debug
        case .info: return .info
        case .warn: return .default
        case .error: return .error
        case .suppress: return .debug
        }
    }
}
#endif
