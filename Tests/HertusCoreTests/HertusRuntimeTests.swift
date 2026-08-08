import XCTest
@testable import HertusCore

/// Startup, and who decides whether Guard runs.
///
/// The answer has to be the SDK, from the environment and the config, without
/// the host app calling anything but `initialize`. These drive the whole path
/// inline: the scheduler and the callback delivery are injected, so there is no
/// queue to pump and no expectation to wait on.
final class HertusRuntimeTests: XCTestCase {

    private let token = String(repeating: "a", count: 64)

    private var factory = SignalEngineFactory()
    private var engine = FakeSignalEngine()

    private var initialized: [Bool] = []
    private var errors: [HertusErrorCode] = []
    private var guardSignals: [(Bool, Double?, HertusError?)] = []

    override func setUp() {
        super.setUp()
        factory = SignalEngineFactory()
        engine = FakeSignalEngine(signal: GuardSignal(
            sealedPayload: "sealed",
            requestId: "req",
            confidence: 0.9,
            source: .engine
        ))
        factory.register(provider: "s1") { [engine] in engine }
        initialized = []
        errors = []
        guardSignals = []
    }

    /// Everything runs inline, so a test asserts immediately after `initialize`.
    private func makeRuntime(settings: GuardSettings?) -> HertusRuntime {
        HertusRuntime(
            factory: factory,
            makeSource: { _, _, _ in StubConfigurationSource(settings: settings) },
            schedule: { work in work() },
            deliver: { work in work() },
            now: { 0 }
        )
    }

    private func makeConfig(
        environment: HertusEnvironment,
        appToken: String? = nil,
        guardEnabled: Bool = true,
        guardInSandbox: Bool = false
    ) -> HertusConfig {
        var config = HertusConfig(appToken: appToken ?? token, environment: environment)
        config.guardEnabled = guardEnabled
        config.guardInSandbox = guardInSandbox
        config.logLevel = .verbose
        config.onInitialized = { [weak self] ready in self?.initialized.append(ready) }
        config.onError = { [weak self] error in self?.errors.append(error.code) }
        config.onGuardSignal = { [weak self] identified, confidence, error in
            self?.guardSignals.append((identified, confidence, error))
        }
        return config
    }

    private func usableSettings() -> GuardSettings {
        GuardSettings(enabled: true, provider: "s1", publicKey: "key", region: "eu")
    }

    // MARK: the point of all this

    /// The host app calls initialize and nothing else. Guard finds its engine
    /// and starts itself.
    func testInitializeStartsGuardWithNoOtherCall() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .production))

        XCTAssertTrue(runtime.isGuardRunning)
        XCTAssertEqual(runtime.state, .ready)
        XCTAssertEqual(initialized, [true])
        XCTAssertNotNil(engine.startedWith, "the engine should have been configured")
    }

    /// One identification per launch, reported to the host app.
    func testInitializeIdentifiesOnceAndReportsIt() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .production))

        XCTAssertEqual(engine.identifyCount, 1)
        XCTAssertEqual(guardSignals.count, 1)
        XCTAssertTrue(guardSignals[0].0, "a sealed payload means the device identified")
        XCTAssertEqual(guardSignals[0].1, 0.9)
        XCTAssertNil(guardSignals[0].2)
    }

    // MARK: the switches, decided inside

    /// Every one of the things Guard exists to flag also describes a developer
    /// testing an integration, so sandbox does not identify unless asked.
    func testSandboxDoesNotIdentifyByDefault() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .sandbox))

        XCTAssertFalse(runtime.isGuardRunning)
        XCTAssertEqual(engine.identifyCount, 0, "sandbox must not spend an identification")
        XCTAssertNil(engine.startedWith, "no engine should have been configured at all")
    }

    func testSandboxIdentifiesWhenAskedTo() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .sandbox, guardInSandbox: true))

        XCTAssertTrue(runtime.isGuardRunning)
        XCTAssertEqual(engine.identifyCount, 1)
    }

    func testGuardEnabledFalseStopsItInProductionToo() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .production, guardEnabled: false))

        XCTAssertFalse(runtime.isGuardRunning)
        XCTAssertNil(engine.startedWith)
    }

    /// A configuration state is not a failure. The SDK still settles, still
    /// reports, and still accepts calls.
    func testGuardOffIsNotAnError() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .sandbox))

        XCTAssertEqual(runtime.state, .ready)
        XCTAssertEqual(initialized, [true])
        XCTAssertTrue(errors.isEmpty, "switching Guard off must not look like something failing")
        XCTAssertTrue(runtime.isEnabled())
    }

    /// The server has the other half of the kill switch, and either half being
    /// false is enough.
    func testTheServerCanSwitchGuardOffOnItsOwn() {
        let runtime = makeRuntime(settings: GuardSettings.off())
        runtime.initialize(makeConfig(environment: .production))

        XCTAssertFalse(runtime.isGuardRunning)
        XCTAssertEqual(runtime.state, .ready)
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: settling

    /// Degraded is a fully functional SDK minus Guard, which is the right state
    /// for a device that could not be told what to do.
    func testNoConfigurationSettlesDegradedRatherThanHanging() {
        let runtime = makeRuntime(settings: nil)
        runtime.initialize(makeConfig(environment: .production))

        XCTAssertEqual(runtime.state, .degraded)
        XCTAssertEqual(initialized, [false], "a host app waiting on this must never be left waiting")
        XCTAssertFalse(runtime.isGuardRunning)
        XCTAssertTrue(runtime.isEnabled(), "degraded still measures")
    }

    /// A malformed token is a programming error, caught on the caller's thread
    /// before any work is scheduled.
    func testAMalformedTokenIsTerminalAndSaysWhy() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .production, appToken: "not-a-token"))

        XCTAssertEqual(runtime.state, .disabled)
        XCTAssertEqual(errors, [.configurationInvalid])
        XCTAssertEqual(initialized, [false])
        XCTAssertFalse(runtime.isEnabled())
        XCTAssertNil(engine.startedWith, "nothing should start behind a bad token")
    }

    func testInitializeIsIgnoredTheSecondTime() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .production))
        runtime.initialize(makeConfig(environment: .production))

        XCTAssertEqual(engine.identifyCount, 1, "the first configuration wins")
        XCTAssertEqual(initialized.count, 1, "initialization is announced once per launch")
    }

    // MARK: the runtime switch

    func testSetEnabledTogglesMeasurement() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .production))

        XCTAssertTrue(runtime.isEnabled())
        runtime.setEnabled(false)
        XCTAssertFalse(runtime.isEnabled())
        runtime.setEnabled(true)
        XCTAssertTrue(runtime.isEnabled())
    }

    /// A rejected token is terminal, so nothing turns measurement back on.
    func testSetEnabledCannotReviveADisabledSdk() {
        let runtime = makeRuntime(settings: usableSettings())
        runtime.initialize(makeConfig(environment: .production, appToken: "bad"))

        runtime.setEnabled(true)
        XCTAssertFalse(runtime.isEnabled())
    }
}

/// Answers immediately with whatever the test chose, so the runtime's own
/// behaviour is what is under test rather than the bootstrap sequence's.
private final class StubConfigurationSource: ConfigurationSource {
    let settings: GuardSettings?

    init(settings: GuardSettings?) {
        self.settings = settings
    }

    func start(listener: ConfigurationListener) {
        guard let settings else {
            listener.configurationUnavailable()
            return
        }
        listener.configurationReady(
            BootstrapConfig(configVersion: "cv1", ttlSeconds: 3_600, guardSettings: settings)
        )
    }
}
