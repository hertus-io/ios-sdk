import Foundation

/// Where the runtime gets the server half of its configuration.
///
/// A protocol so that the bootstrap client can be dropped in when it exists
/// without the runtime changing, and so a test can drive the whole startup path
/// without a network.
public protocol GuardSettingsSource {
    /// Answers exactly once, with nil when no configuration could be obtained.
    func load(completion: @escaping (GuardSettings?) -> Void)
}

/// The source until bootstrap exists.
///
/// It answers nil, which settles the SDK into `degraded`: fully functional
/// minus Guard, which is the correct state for a device that could not be told
/// what to do. See docs/SDK.md, "Degradation".
public struct UnavailableGuardSettingsSource: GuardSettingsSource {

    public init() {}

    public func load(completion: @escaping (GuardSettings?) -> Void) {
        completion(nil)
    }
}

/// Everything the SDK actually does, off the caller's thread.
///
/// `Hertus` is a facade over one of these. The split exists so the namespace has
/// no logic in it and this has no global state: a test constructs one, drives
/// it, and throws it away.
///
/// **Guard is started here, not by the host app.** Which engine exists is found
/// at runtime, and whether it runs is decided from `guardEnabled`, the
/// environment and the server's answer, in that order. A host app calls
/// `initialize` and nothing else, exactly as on Android.
///
/// **Nothing here throws into a host app.** The SDK is a measurement library
/// sitting in somebody's startup path, and no fraud signal is worth crashing
/// their product over. Every failure ends as a log line and a `HertusError`
/// handed to a handler.
public final class HertusRuntime {

    /// How background work is scheduled. Injected so a test can run it inline.
    public typealias Scheduler = (@escaping () -> Void) -> Void

    /// The SDK's own queue: serial, and below the host app's work. Measurement
    /// is never the reason somebody's frame was dropped.
    private static let queue = DispatchQueue(label: "io.hertus.sdk", qos: .utility)

    private let factory: SignalEngineFactory
    private let settingsSource: GuardSettingsSource
    private let schedule: Scheduler
    private let deliver: CallbackDispatcher.Deliver
    private let now: () -> TimeInterval

    private let states = SdkStateHolder()
    private let lock = NSLock()

    private var initialized = false
    private var enabled = true
    private var log: Logger?
    private var callbacks: CallbackDispatcher?
    private var guardModule: HertusGuard?

    /// - Parameters:
    ///   - schedule: how background work runs. Nil uses the SDK's own serial
    ///     queue, which is private, so the default is resolved here rather than
    ///     in the signature.
    ///   - deliver: how a callback reaches the host app. Nil uses the main queue.
    public init(
        factory: SignalEngineFactory = .shared,
        settingsSource: GuardSettingsSource = UnavailableGuardSettingsSource(),
        schedule: Scheduler? = nil,
        deliver: CallbackDispatcher.Deliver? = nil,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.factory = factory
        self.settingsSource = settingsSource
        self.schedule = schedule ?? { work in HertusRuntime.queue.async(execute: work) }
        self.deliver = deliver ?? { work in DispatchQueue.main.async(execute: work) }
        self.now = now
    }

    public var state: SdkState { states.current }

    /// Whether Guard is running. False until startup settles, and false forever
    /// on a device the switches turned off.
    public var isGuardRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return guardModule?.isRunning ?? false
    }

    /// Starts the SDK. Returns immediately.
    ///
    /// The token is validated here, on the caller's thread, because a malformed
    /// one is a programming error and the developer is watching the console
    /// right now. Everything after this point is somebody's network being bad.
    public func initialize(_ config: HertusConfig) {
        let logger = Logger(level: config.logLevel, environment: config.environment)

        lock.lock()
        if initialized {
            lock.unlock()
            logger.w("initialize called more than once; ignoring the second call")
            return
        }
        initialized = true
        lock.unlock()

        let endpoint = ServerEndpoints.resolve(override: config.serverUrl, environment: config.environment)
        if endpoint.refusedOverride {
            logger.w("serverUrl was refused; using the default for \(config.environment.wireValue)")
        }

        let dispatcher = CallbackDispatcher(
            onInitialized: config.onInitialized,
            onError: config.onError,
            onGuardSignal: config.onGuardSignal,
            deliver: deliver
        )

        lock.lock()
        log = logger
        callbacks = dispatcher
        lock.unlock()

        guard AppToken.isWellFormed(config.appToken) else {
            logger.e(AppToken.malformedMessage)
            states.move(to: .disabled)
            dispatcher.deliverError(.configurationInvalid)
            dispatcher.announceInitialized(ready: false)
            return
        }

        let module = HertusGuard(log: logger, factory: factory, now: now)

        lock.lock()
        guardModule = module
        lock.unlock()

        states.move(to: .initializing)

        // The reason comes from Guard rather than being restated here, so this
        // line and the one Guard logs later cannot disagree. It matters that it
        // is on this one: Guard only speaks once the configuration has arrived,
        // and a developer whose network is down still needs to know Guard was
        // never going to run.
        let guardOff = HertusGuard.clientOffReason(
            clientEnabled: config.guardEnabled,
            guardInSandbox: config.guardInSandbox,
            environment: config.environment
        )
        let guardState = guardOff.map { "off, \($0)" } ?? "requested"
        logger.i(
            "initialize(env=\(config.environment.wireValue), sdk=\(SdkInfo.version), "
                + "server=\(endpoint.url), guard=\(guardState))"
        )

        schedule { [weak self] in
            self?.startUp(config: config, logger: logger, dispatcher: dispatcher, module: module)
        }
    }

    /// Turns measurement off, or back on, at runtime.
    ///
    /// For an in-app privacy toggle. The setting is not persisted. A host app
    /// that offers the choice owns storing it and re-applies it after
    /// `initialize` on the next launch. Persisting it here would mean the SDK
    /// silently overriding a decision the app thinks it is making.
    public func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        let logger = log
        lock.unlock()

        logger?.i("setEnabled(\(value))")
    }

    /// Whether the SDK is currently measuring.
    ///
    /// False when switched off with `setEnabled`, and also when the server
    /// rejected this app's token. The difference is in the log, not here.
    public func isEnabled() -> Bool {
        lock.lock()
        let value = enabled
        lock.unlock()
        return value && !states.current.isTerminal
    }

    // MARK: startup

    private func startUp(
        config: HertusConfig,
        logger: Logger,
        dispatcher: CallbackDispatcher,
        module: HertusGuard
    ) {
        settingsSource.load { [weak self] settings in
            guard let self else { return }

            guard let settings else {
                // No configuration means no Guard, and it is not a failure the
                // host app can act on. Degraded is a fully functional SDK minus
                // identification, which is the correct state for a device that
                // could not be told what to do.
                logger.w("no configuration is available, so Guard stays off for this launch")
                self.states.move(to: .degraded)
                dispatcher.announceInitialized(ready: false)
                return
            }

            // Guard re-checks the client switches itself, so the decision lives
            // in one place rather than being made here and again there.
            module.start(
                settings: settings,
                clientEnabled: config.guardEnabled,
                guardInSandbox: config.guardInSandbox,
                environment: config.environment,
                sdkVersion: SdkInfo.version
            )

            self.identifyOnce(module: module, dispatcher: dispatcher)

            self.states.move(to: .ready)
            dispatcher.announceInitialized(ready: true)
        }
    }

    /// One identification per launch.
    ///
    /// This slice reports the result to the host app. It does not upload it:
    /// there is no ingest endpoint to upload it to. See docs/SDK.md, "What must
    /// exist first".
    private func identifyOnce(module: HertusGuard, dispatcher: CallbackDispatcher) {
        module.identify { signal, error, _ in
            dispatcher.deliverGuardSignal(
                identified: signal?.identified ?? false,
                confidence: signal?.confidence,
                error: error
            )
        }
    }
}
