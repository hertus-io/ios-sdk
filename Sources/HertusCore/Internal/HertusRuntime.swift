import Foundation

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
    public typealias Scheduler = (@escaping @Sendable () -> Void) -> Void

    /// Builds the configuration source once the token has been accepted.
    ///
    /// A closure rather than a value because the real source needs the app
    /// token, the environment and the resolved server URL, none of which exist
    /// until `initialize` is called.
    public typealias SourceFactory = (HertusConfig, String, Logger) -> ConfigurationSource

    /// Builds the ingest pipeline once the server has said where events go.
    ///
    /// A closure for the same reason as `SourceFactory`: the endpoint is not
    /// known until bootstrap has answered.
    public typealias PipelineFactory = (HertusConfig, String, Logger) -> IngestPipeline

    /// The SDK's own queue: serial, and below the host app's work. Measurement
    /// is never the reason somebody's frame was dropped.
    private static let queue = DispatchQueue(label: "io.hertus.sdk", qos: .utility)

    private let factory: SignalEngineFactory
    private let makeSource: SourceFactory
    private let makePipeline: PipelineFactory
    private let schedule: Scheduler
    private let deliver: CallbackDispatcher.Deliver
    private let now: () -> TimeInterval

    private var source: ConfigurationSource?
    private var pipeline: IngestPipeline?
    private var settledConfig: HertusConfig?
    private var settledGuard: HertusGuard?
    private var settledCallbacks: CallbackDispatcher?
    private var settledServerUrl: String?

    private let states = SdkStateHolder()
    private let lock = NSLock()

    private var initialized = false
    private var enabled = true
    private var log: Logger?
    private var callbacks: CallbackDispatcher?
    private var guardModule: HertusGuard?

    /// - Parameters:
    ///   - makeSource: how configuration is obtained. Nil builds the real one,
    ///     which reads the cache and talks to the server.
    ///   - schedule: how background work runs. Nil uses the SDK's own serial
    ///     queue, which is private, so the default is resolved here rather than
    ///     in the signature.
    ///   - deliver: how a callback reaches the host app. Nil uses the main queue.
    public init(
        factory: SignalEngineFactory = .shared,
        makeSource: SourceFactory? = nil,
        makePipeline: PipelineFactory? = nil,
        schedule: Scheduler? = nil,
        deliver: CallbackDispatcher.Deliver? = nil,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.factory = factory
        self.makeSource = makeSource ?? HertusRuntime.defaultSource
        self.makePipeline = makePipeline ?? HertusRuntime.defaultPipeline
        self.schedule = schedule ?? { work in HertusRuntime.queue.async(execute: work) }
        self.deliver = deliver ?? { work in DispatchQueue.main.async(execute: work) }
        self.now = now
    }

    /// The cache, the server, and the rules for choosing between them.
    public static let defaultSource: SourceFactory = { config, serverUrl, log in
        let device = DeviceInfoReader.read(sdkVersion: SdkInfo.version)

        return BootstrapConfigurationSource(
            cache: BootstrapCache(appToken: config.appToken, environment: config.environment),
            newFetcher: {
                BootstrapClient(
                    baseUrl: serverUrl,
                    appToken: config.appToken,
                    environment: config.environment,
                    device: device,
                    log: log
                )
            },
            log: log
        )
    }

    /// The queue, the uploader, and the batching rules.
    public static let defaultPipeline: PipelineFactory = { config, ingestUrl, log in
        let device = DeviceInfoReader.read(sdkVersion: SdkInfo.version)

        return IngestPipeline(
            queue: EventQueue(
                store: FileEventStore(
                    appToken: config.appToken,
                    environment: config.environment,
                    log: log
                ),
                log: log
            ),
            uploader: IngestClient(
                baseUrl: ingestUrl,
                appToken: config.appToken,
                environment: config.environment,
                device: device,
                log: log
            ),
            log: log,
            delay: BootstrapConfigurationSource.defaultDelay
        )
    }

    public var state: SdkState { states.current }

    /// How many events are waiting to be sent. For a host app's diagnostics.
    public var pendingEventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pipeline?.pending ?? 0
    }

    /// Records one event.
    ///
    /// Queued rather than sent, and safe to call before startup finishes: what
    /// is raised during startup is held and goes out with the first batch.
    /// Events raised before `initialize` are dropped, which is a programming
    /// error a developer can fix.
    public func track(_ event: HertusEvent) {
        lock.lock()
        let running = initialized
        let logger = log
        lock.unlock()

        guard running else { return }
        guard isEnabled() else { return }

        if !event.isWellFormed {
            // Once per event rather than once per parameter, and at debug: a
            // refused parameter is worth finding and is not worth a warning on
            // every call.
            logger?.d("event '\(event.name)' refused \(event.rejections.count) parameter(s): "
                + event.rejections.map(\.description).joined(separator: ", "))
        }

        let envelope = event.envelope(
            eventId: UUID().uuidString,
            occurredAtMillis: Int64(now() * 1000)
        )

        guard let payload = envelope.jsonString() else {
            logger?.w("event '\(event.name)' could not be serialized and was dropped")
            return
        }

        schedule { [weak self] in
            self?.pipelineForTracking()?.track(payload)
        }
    }

    /// Asks the SDK to upload what it is holding.
    ///
    /// Advisory: the SDK decides when it actually goes.
    public func flush() {
        schedule { [weak self] in
            self?.pipelineForTracking()?.flush()
        }
    }

    private func pipelineForTracking() -> IngestPipeline? {
        lock.lock()
        defer { lock.unlock() }
        return pipeline
    }

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

        let built = makeSource(config, endpoint.url, logger)

        lock.lock()
        source = built
        settledConfig = config
        settledGuard = module
        settledCallbacks = dispatcher
        settledServerUrl = endpoint.url
        lock.unlock()

        schedule { [weak self] in
            guard let self else { return }
            built.start(listener: self)
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

    /// One identification per launch.
    ///
    /// The result reaches the host app and, when there is one, the ingest
    /// pipeline: every batch after this carries it as evidence that the device
    /// is what it claims to be. Batches sent before it arrives carry none, which
    /// is correct rather than unfortunate.
    private func identifyOnce(module: HertusGuard, dispatcher: CallbackDispatcher) {
        module.identify { [weak self] signal, error, _ in
            self?.pipelineForTracking()?.setEvidence(GuardEvidence(signal: signal))

            dispatcher.deliverGuardSignal(
                identified: signal?.identified ?? false,
                confidence: signal?.confidence,
                error: error
            )
        }
    }

    private func settled() -> (HertusConfig, HertusGuard, CallbackDispatcher)? {
        lock.lock()
        defer { lock.unlock() }
        guard let config = settledConfig, let module = settledGuard, let dispatcher = settledCallbacks
        else { return nil }
        return (config, module, dispatcher)
    }
}

// MARK: ConfigurationListener

extension HertusRuntime: ConfigurationListener {

    /// May arrive more than once. A configuration that lands behind an already
    /// announced failure upgrades the SDK in place, and a revalidation that
    /// finds a changed configuration restarts Guard on it.
    public func configurationReady(_ config: BootstrapConfig) {
        guard let (hostConfig, module, dispatcher) = settled() else { return }

        startIngest(config, hostConfig)

        // Guard re-checks the client switches itself, so the decision lives in
        // one place rather than being made here and again there.
        module.start(
            settings: config.guardSettings,
            clientEnabled: hostConfig.guardEnabled,
            guardInSandbox: hostConfig.guardInSandbox,
            environment: hostConfig.environment,
            sdkVersion: SdkInfo.version
        )

        identifyOnce(module: module, dispatcher: dispatcher)

        states.move(to: .ready)
        dispatcher.announceInitialized(ready: true)
    }

    /// No configuration means no Guard, and it is not a failure the host app can
    /// act on. Degraded is a fully functional SDK minus identification, which is
    /// the correct state for a device that could not be told what to do.
    public func configurationUnavailable() {
        guard let (_, _, dispatcher) = settled() else { return }

        states.move(to: .degraded)
        dispatcher.announceInitialized(ready: false)
        dispatcher.deliverError(.serverUnavailable)
    }

    /// A token that is not ours will not become ours by asking again.
    ///
    /// The queue goes with it. Holding events for a token that will never be
    /// accepted is a queue that only ever grows.
    public func configurationRejected() {
        guard let (_, _, dispatcher) = settled() else { return }

        pipelineForTracking()?.stop()

        states.move(to: .disabled)
        dispatcher.deliverError(.serverRejected)
        dispatcher.announceInitialized(ready: false)
    }

    /// Builds the pipeline the first time a configuration says where events go.
    ///
    /// Only once: a revalidation that changes the configuration restarts Guard,
    /// but rebuilding the pipeline would throw away whatever it is holding.
    ///
    /// The endpoint the server names wins, and the ordinary server URL is the
    /// fallback, so ingest can be moved without a client release. It is checked
    /// like any other value that arrived over the network.
    private func startIngest(_ config: BootstrapConfig, _ hostConfig: HertusConfig) {
        lock.lock()
        let alreadyBuilt = pipeline != nil
        let serverUrl = settledServerUrl
        let logger = log
        lock.unlock()

        guard !alreadyBuilt, let serverUrl, let logger else { return }

        guard config.ingestEnabled else {
            logger.d("ingest is off for this app; events will not be queued")
            return
        }

        let named = UrlPolicy.accept(config.ingestEndpoint, environment: hostConfig.environment)
        if config.ingestEndpoint != nil, named == nil {
            logger.w("the configured ingest endpoint was refused; using the server URL")
        }

        let built = makePipeline(hostConfig, named ?? serverUrl, logger)

        lock.lock()
        pipeline = built
        lock.unlock()

        logger.i("ingest on: endpoint=\(named != nil ? "configured" : "default"), \(built.pending) queued")

        // A queue recovered from a previous launch goes out now rather than
        // waiting for enough new events to reach a batch.
        if built.pending > 0 {
            built.flush()
        }
    }

    public func configurationError(_ code: HertusErrorCode) {
        guard let (_, _, dispatcher) = settled() else { return }
        dispatcher.deliverError(code)
    }
}
