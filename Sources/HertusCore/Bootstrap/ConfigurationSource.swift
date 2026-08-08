import Foundation

/// What the runtime is told about its configuration.
///
/// May be called more than once for one launch: a failure followed by a later
/// success upgrades the SDK in place, which is the whole reason the degraded
/// state exists.
public protocol ConfigurationListener: AnyObject {

    func configurationReady(_ config: BootstrapConfig)

    /// No configuration. The SDK runs without Guard.
    func configurationUnavailable()

    /// The server refused this token. Terminal for the process.
    func configurationRejected()

    /// A failure worth reporting that does not settle the SDK either way.
    func configurationError(_ code: HertusErrorCode)
}

/// Where the runtime gets its configuration.
///
/// A protocol so the runtime does not care whether the answer came from a cache,
/// a server, or a test.
public protocol ConfigurationSource: AnyObject {
    func start(listener: ConfigurationListener)
}

/// The source that answers nothing.
///
/// For a runtime constructed without one, and for tests that only care about
/// what the SDK does when it cannot be told what to do. It settles the SDK into
/// degraded, which is fully functional minus Guard.
public final class UnavailableConfigurationSource: ConfigurationSource {

    public init() {}

    public func start(listener: ConfigurationListener) {
        listener.configurationUnavailable()
    }
}

/// The real source: the cache, the server, and the rules for choosing between
/// them.
///
/// Owns a `BootstrapSequence` and translates its outcomes for the runtime. The
/// translation is thin on purpose; the decisions all live in the sequence, where
/// they can be tested without a runtime.
public final class BootstrapConfigurationSource: ConfigurationSource, BootstrapSequenceListener {

    private let cache: ConfigurationStore
    private let newFetcher: () -> ConfigurationFetcher
    private let log: Logger
    private let delay: BootstrapSequence.DelayScheduler

    private var sequence: BootstrapSequence?
    private weak var listener: ConfigurationListener?

    public init(
        cache: ConfigurationStore,
        newFetcher: @escaping () -> ConfigurationFetcher,
        log: Logger,
        delay: @escaping BootstrapSequence.DelayScheduler = BootstrapConfigurationSource.defaultDelay
    ) {
        self.cache = cache
        self.newFetcher = newFetcher
        self.log = log
        self.delay = delay
    }

    /// Retries land on a background queue, never the caller's.
    public static let defaultDelay: BootstrapSequence.DelayScheduler = { delayMs, work in
        DispatchQueue.global(qos: .utility)
            .asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: work)
    }

    public func start(listener: ConfigurationListener) {
        self.listener = listener

        let running = BootstrapSequence(
            cache: cache,
            newFetcher: newFetcher,
            log: log,
            delay: delay,
            listener: self
        )
        sequence = running
        running.start()
    }

    // MARK: BootstrapSequenceListener

    public func onConfigurationReady(_ config: BootstrapConfig) {
        listener?.configurationReady(config)
    }

    public func onUnavailable() {
        listener?.configurationUnavailable()
    }

    public func onRejected() {
        listener?.configurationRejected()
    }

    public func onRecoverableError(_ code: HertusErrorCode) {
        listener?.configurationError(code)
    }

    public func onRevalidationDue(configVersion: String?) {
        // Behind the cache that is already being served, so it must not block
        // the launch it is running behind.
        delay(0) { [weak self] in
            self?.sequence?.revalidate(configVersion: configVersion)
        }
    }
}
