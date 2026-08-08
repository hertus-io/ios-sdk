import Foundation

/// What a bootstrap run can conclude.
///
/// A protocol rather than a set of closures because these are one decision seen
/// from five angles, and a caller that implements four of them has a bug the
/// compiler should be pointing at.
public protocol BootstrapSequenceListener: AnyObject {

    /// A usable configuration arrived, from wherever. Guard can start.
    func onConfigurationReady(_ config: BootstrapConfig)

    /// No configuration is available and the SDK should run without Guard.
    /// Called once per run, however many attempts follow it.
    func onUnavailable()

    /// The server refused this token. Terminal for the process.
    func onRejected()

    /// A failure worth reporting that does not settle the SDK either way.
    func onRecoverableError(_ code: HertusErrorCode)

    /// A cache was served and is past half its life, so it should be refreshed
    /// behind it.
    func onRevalidationDue(configVersion: String?)
}

/// Getting a usable configuration, from the cache or from the server.
///
/// The whole of startup's decision making, separated so a test can drive it
/// with a scripted fetcher and a fake clock rather than a device and a network.
/// It owns no state that outlives a run and reports every outcome through
/// `BootstrapSequenceListener`.
///
/// Retries are scheduled rather than slept through, because the platform's HTTP
/// is asynchronous and blocking a queue to wait for it would hold a thread for
/// the whole of a bad network.
public final class BootstrapSequence {

    /// How a retry is delayed. Injected so a test runs one instantly.
    public typealias DelayScheduler = (_ delayMs: Int64, _ work: @escaping @Sendable () -> Void) -> Void

    private let cache: ConfigurationStore
    private let newFetcher: () -> ConfigurationFetcher
    private let log: Logger
    private let delay: DelayScheduler

    private weak var listener: BootstrapSequenceListener?

    private var fetcher: ConfigurationFetcher?
    private var usable: CachedConfiguration?
    private var validator: String?
    private var attempt = 0
    private var reportedUnavailable = false

    public init(
        cache: ConfigurationStore,
        newFetcher: @escaping () -> ConfigurationFetcher,
        log: Logger,
        delay: @escaping DelayScheduler,
        listener: BootstrapSequenceListener
    ) {
        self.cache = cache
        self.newFetcher = newFetcher
        self.log = log
        self.delay = delay
        self.listener = listener
    }

    /// Reads the cache, then fetches if it has to.
    ///
    /// A fresh cache is the common path and costs no network at all, which is
    /// why it is tried before anything else rather than as a fallback.
    public func start() {
        let cached = cache.read()

        if let cached, !cached.expired, cached.fresh {
            log.i("bootstrap cache hit (age \(cached.ageSeconds)s, ttl \(cached.ttlSeconds)s)")

            if let parsed = BootstrapParser.parse(cached.payload) {
                listener?.onConfigurationReady(parsed)
                if cached.shouldRevalidate {
                    log.d("cache is past half its life; refreshing behind it")
                    listener?.onRevalidationDue(configVersion: cached.configVersion)
                }
                return
            }

            // A cached payload that no longer parses means this build changed
            // its mind about the contract. Dropping it and refetching is the
            // only way out, and it happens once.
            log.w("cached configuration could not be parsed; discarding it")
            cache.clear()
            beginFetch(usable: nil)
            return
        }

        beginFetch(usable: cached)
    }

    /// Revalidates behind a cache that is already being served.
    ///
    /// A failure here changes nothing: what is running stays running, and the
    /// cache keeps its existing age.
    public func revalidate(configVersion: String?) {
        newFetcher().fetch(configVersion: configVersion) { [weak self] outcome in
            guard let self else { return }

            switch outcome {
            case .notModified:
                self.cache.touch()
                self.log.d("revalidated; configuration unchanged")

            case .fetched(let payload):
                guard let parsed = BootstrapParser.parse(payload) else { return }
                self.cache.write(
                    payload: payload,
                    configVersion: parsed.configVersion,
                    ttlSeconds: parsed.ttlSeconds
                )
                self.log.i("configuration changed (cv=\(parsed.configVersion ?? "none")); restarting Guard")
                self.listener?.onConfigurationReady(parsed)

            case .rejected, .unavailable:
                self.log.d("revalidation failed; keeping the current configuration")
            }
        }
    }

    // MARK: fetching

    /// - Parameter usable: a cached entry that parsed, if there is one. It
    ///   supplies the validator and is the fallback when the network will not
    ///   cooperate.
    private func beginFetch(usable: CachedConfiguration?) {
        self.usable = usable
        self.validator = usable?.configVersion
        self.attempt = 0
        self.reportedUnavailable = false
        self.fetcher = newFetcher()
        attemptFetch()
    }

    private func attemptFetch() {
        fetcher?.fetch(configVersion: validator) { [weak self] outcome in
            self?.handle(outcome)
        }
    }

    /// Reports the outcome after the first failure rather than after the last.
    ///
    /// The obvious design, retry five times and then tell the host app, means
    /// `onInitialized` does not fire for over a minute on a dead network, which
    /// makes the SDK look hung during exactly the situation it exists to
    /// survive. So the first failure settles the SDK and announces it, and the
    /// retries continue behind that. A later success upgrades it in place.
    private func handle(_ outcome: BootstrapOutcome) {
        switch outcome {
        case .fetched(let payload):
            if let parsed = BootstrapParser.parse(payload) {
                cache.write(
                    payload: payload,
                    configVersion: parsed.configVersion,
                    ttlSeconds: parsed.ttlSeconds
                )
                log.i(
                    "bootstrap 200 cv=\(parsed.configVersion ?? "none") ttl=\(parsed.ttlSeconds)s "
                        + "ingest=\(parsed.ingestEnabled ? "on" : "off")"
                )
                listener?.onConfigurationReady(parsed)
                return
            }

            // A 200 the SDK cannot read is the server's problem and it will very
            // likely still be unreadable in one second. This counts as an
            // attempt: without that it is an unbacked-off loop against a server
            // that is already misbehaving.
            log.w("bootstrap returned something unparseable")
            listener?.onRecoverableError(.serverUnavailable)
            attempt += 1
            retryOrStop(retryAfterSeconds: nil)

        case .notModified:
            cache.touch()
            log.i("bootstrap 304; the cached configuration is current")

            if let usable, let parsed = BootstrapParser.parse(usable.payload) {
                listener?.onConfigurationReady(parsed)
                return
            }

            // 304 against a validator with nothing behind it is a server bug.
            // Ask again without the validator, and count it, so a server that
            // answers 304 unconditionally cannot pin the SDK in a loop.
            log.w("bootstrap answered 304 but nothing is cached; refetching")
            cache.clear()
            validator = nil
            attempt += 1
            retryOrStop(retryAfterSeconds: nil)

        case .rejected(let status):
            log.e(
                "bootstrap \(status): this app token was rejected. Nothing will be measured. "
                    + "Check the key in Developer tools -> SDK credentials, and that the app is "
                    + "not archived."
            )
            listener?.onRejected()

        case .unavailable(let reason, let retryAfterSeconds):
            // A stale cache beats no configuration: the alternative for a device
            // that has been offline since Tuesday is no measurement at all.
            if let usable, !usable.expired, let parsed = BootstrapParser.parse(usable.payload) {
                log.w("bootstrap unavailable (\(reason)); using a stale cache (age \(usable.ageSeconds)s)")
                listener?.onConfigurationReady(parsed)
                return
            }

            attempt += 1
            if !reportedUnavailable {
                reportedUnavailable = true
                log.w("bootstrap unavailable (\(reason)); continuing without Guard")
                listener?.onUnavailable()
            }
            retryOrStop(retryAfterSeconds: retryAfterSeconds)
        }
    }

    /// Schedules the next attempt, or reports that there will not be one.
    private func retryOrStop(retryAfterSeconds: Int64?) {
        guard attempt < Backoff.maxAttempts else {
            log.w("bootstrap gave up after \(attempt) attempts; Guard stays off for this launch")
            return
        }

        delay(Backoff.delayMillis(attempt: attempt, retryAfterSeconds: retryAfterSeconds)) {
            [weak self] in self?.attemptFetch()
        }
    }
}
