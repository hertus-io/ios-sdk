import Foundation

/// The fraud module, as the rest of the SDK sees it.
///
/// Owns which engine is running and whether it should be running at all, so
/// that nothing above this has to hold either question. Callers get a
/// `GuardSignal` or an error, and "Guard is switched off" is a signal rather
/// than an error. See `GuardSource.disabled`.
///
/// Named `HertusGuard` because `guard` is a Swift keyword and a type that has
/// to be written in backticks at every call site is a type nobody enjoys using.
///
/// Runs on the SDK's single serial queue and is not otherwise thread safe.
public final class HertusGuard {

    private let log: Logger
    private let factory: SignalEngineFactory

    private var engine: SignalEngine = NoopSignalEngine()
    private var running = false
    private var timeoutMs: Int64 = GuardSettings.defaultIdentifyTimeoutMs

    /// Supplies the clock for the duration in the log line, so a test can make
    /// it deterministic.
    private let now: () -> TimeInterval

    public init(
        log: Logger,
        factory: SignalEngineFactory = .shared,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.log = log
        self.factory = factory
        self.now = now
    }

    /// Whether an engine is configured and will be asked.
    public var isRunning: Bool { running }

    /// Configures Guard from the bootstrap response.
    ///
    /// Every path that ends with Guard not running logs why at info. This is
    /// the question a developer asks first when a fraud signal is missing, and
    /// the answer being one search away is worth the lines.
    public func start(
        settings: GuardSettings,
        clientEnabled: Bool,
        guardInSandbox: Bool,
        environment: HertusEnvironment,
        sdkVersion: String
    ) {
        shutdown()

        // Asked before the server's answer is even looked at, so that a device
        // which is never going to identify does not construct an engine to
        // discover it. The reasons here are the host app's own.
        if let local = HertusGuard.clientOffReason(
            clientEnabled: clientEnabled,
            guardInSandbox: guardInSandbox,
            environment: environment
        ) {
            log.i("guard off: \(local)")
            return
        }

        if let unusable = settings.unusableReason {
            // Enabled-but-incomplete is a server-side mistake, and naming the
            // missing field beats letting the engine fail on every launch with
            // an error that points at the wrong thing.
            if settings.enabled {
                log.w("guard off: \(unusable)")
            } else {
                log.i("guard off: \(unusable)")
            }
            return
        }

        guard factory.canResolve(settings.provider) else {
            log.i("guard off: this build has no engine for provider '\(settings.provider ?? "none")'")
            return
        }

        let candidate = factory.resolve(settings.provider)

        if candidate is NoopSignalEngine {
            // The provider is registered but the factory produced nothing
            // usable. Distinct from the case above so the log says which of the
            // two happened.
            log.w("guard off: engine '\(settings.provider ?? "none")' could not be constructed")
            return
        }

        // The endpoint arrives over the network and is handed to a component
        // that will make requests to it, so it is checked like any other
        // untrusted input. A rejected one falls back to the engine's own
        // default rather than failing: identification through the vendor is
        // worse than identification through our proxy, and much better than
        // none.
        let endpoint = UrlPolicy.accept(settings.endpoint, environment: environment)
        if settings.endpoint != nil && endpoint == nil {
            log.w("guard: the configured endpoint was refused; falling back to the engine default")
        }

        timeoutMs = settings.identifyTimeoutMs
        engine = candidate
        engine.start(
            config: GuardConfig(
                publicKey: settings.publicKey ?? "",
                region: settings.region,
                endpoint: endpoint,
                endpointFallbacks: settings.endpointFallbacks.compactMap {
                    UrlPolicy.accept($0, environment: environment)
                },
                sealedResults: settings.sealedResults,
                extendedResult: settings.extendedResult,
                locationDataEnabled: settings.locationDataEnabled,
                identifyTimeoutMs: settings.identifyTimeoutMs,
                sdkVersion: sdkVersion
            )
        )
        running = true

        log.i(
            "guard on: provider=\(settings.provider ?? "none") "
                + "endpoint=\(endpoint != nil ? "proxy" : "default") "
                + "sealed=\(settings.sealedResults) timeout=\(timeoutMs)ms"
        )
    }

    /// Attempts one identification.
    ///
    /// When Guard is not running this answers `GuardSignal.disabled()` with no
    /// error, promptly. A caller must not have to distinguish "off" from
    /// "broken" by inspecting an error it then ignores.
    public func identify(handler: @escaping EngineResultHandler) {
        guard running else {
            handler(GuardSignal.disabled(), nil, nil)
            return
        }

        let started = now()

        // `log` and `now` are captured by value rather than through self, so a
        // handler that outlives this Guard still logs and still measures.
        engine.identify(timeoutMs: timeoutMs) { [log, now] signal, error, diagnostic in
            let elapsedMs = Int64((now() - started) * 1000)

            // The engine's own words, at verbose only. This is the single
            // channel by which a vendor's wording may reach a console, and it
            // does not exist in production builds. See Logger.
            if let diagnostic {
                log.v("guard engine said: \(diagnostic)")
            }

            if let error {
                log.w("guard identify failed after \(elapsedMs)ms: \(error.wireValue)")
            } else if let signal {
                let sealed = signal.sealedPayload.map { "present(\($0.count) chars)" } ?? "absent"
                let score = signal.confidence.map { "\($0)" } ?? "none"
                log.i("guard identify ok in \(elapsedMs)ms: sealed=\(sealed) confidence=\(score)")
            }

            // An engine that calls back with neither a signal nor an error has
            // broken its contract. Normalised here so nothing downstream has to
            // handle a nil-nil pair.
            let normalised: HertusError?
            if signal == nil && error == nil {
                normalised = HertusError(code: .guardResponseInvalid)
            } else {
                normalised = error
            }

            handler(signal, normalised, diagnostic)
        }
    }

    public func shutdown() {
        if running {
            engine.shutdown()
        }
        engine = NoopSignalEngine()
        running = false
    }

    /// Why this device will not identify whatever the server said, or nil if
    /// the server's configuration is the only remaining question.
    ///
    /// Separate from `start` because it is the whole decision, and a static
    /// function is one a test can state the rules against directly.
    ///
    /// A reason string rather than a boolean, for the reason
    /// `GuardSettings.unusableReason` gives: "Guard is off" without saying
    /// which switch did it is the log line that sends somebody to the dashboard
    /// when the answer was in their own source.
    public static func clientOffReason(
        clientEnabled: Bool,
        guardInSandbox: Bool,
        environment: HertusEnvironment
    ) -> String? {
        // Checked first: it is the explicit instruction, and a developer who
        // wrote `guardEnabled = false` should be told that is what did it
        // rather than something about their environment.
        if !clientEnabled {
            return "disabled by HertusConfig.guardEnabled"
        }

        if environment == .sandbox && !guardInSandbox {
            return "sandbox does not identify devices; set HertusConfig.guardInSandbox = true to run it here"
        }

        return nil
    }
}
