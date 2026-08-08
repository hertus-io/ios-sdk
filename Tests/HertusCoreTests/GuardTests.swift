import XCTest
@testable import HertusCore

// MARK: doubles

/// An engine whose every answer the test chooses.
final class FakeSignalEngine: SignalEngine {

    var startedWith: GuardConfig?
    var shutdownCount = 0
    var identifyCount = 0
    var lastTimeoutMs: Int64?

    var signal: GuardSignal?
    var error: HertusError?
    var diagnostic: String?

    init(signal: GuardSignal? = nil, error: HertusError? = nil, diagnostic: String? = nil) {
        self.signal = signal
        self.error = error
        self.diagnostic = diagnostic
    }

    func start(config: GuardConfig) { startedWith = config }

    func identify(timeoutMs: Int64, handler: @escaping EngineResultHandler) {
        identifyCount += 1
        lastTimeoutMs = timeoutMs
        handler(signal, error, diagnostic)
    }

    func shutdown() { shutdownCount += 1 }
}

/// A logger that keeps what it was told, so a test can assert that Guard
/// explained itself.
func recordingLogger(
    level: HertusLogLevel = .verbose,
    environment: HertusEnvironment = .sandbox,
    into lines: @escaping (String) -> Void
) -> Logger {
    Logger(level: level, environment: environment) { _, message in lines(message) }
}

// MARK: the client-side switches

final class GuardClientSwitchTests: XCTestCase {

    func testExplicitDisableIsReportedAheadOfTheEnvironment() {
        let reason = HertusGuard.clientOffReason(
            clientEnabled: false,
            guardInSandbox: true,
            environment: .production
        )

        XCTAssertNotNil(reason)
        XCTAssertTrue(
            reason!.contains("guardEnabled"),
            "a developer who wrote guardEnabled = false must be told that is what did it"
        )
    }

    /// Every one of the things Guard exists to flag also describes a developer
    /// testing an integration, so sandbox does not identify unless asked.
    func testSandboxDoesNotIdentifyUnlessAsked() {
        let reason = HertusGuard.clientOffReason(
            clientEnabled: true,
            guardInSandbox: false,
            environment: .sandbox
        )

        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("guardInSandbox"), "the reason must name the way out")
    }

    func testSandboxIdentifiesWhenAsked() {
        XCTAssertNil(
            HertusGuard.clientOffReason(
                clientEnabled: true,
                guardInSandbox: true,
                environment: .sandbox
            )
        )
    }

    /// guardInSandbox has no meaning in production, where the switches are
    /// guardEnabled and the server alone.
    func testProductionIgnoresTheSandboxSwitch() {
        XCTAssertNil(
            HertusGuard.clientOffReason(
                clientEnabled: true,
                guardInSandbox: false,
                environment: .production
            )
        )
    }
}

// MARK: settings

final class GuardSettingsTests: XCTestCase {

    private func usable() -> GuardSettings {
        GuardSettings(enabled: true, provider: "s1", publicKey: "key", region: "eu")
    }

    func testACompleteConfigurationIsUsable() {
        XCTAssertTrue(usable().usable)
        XCTAssertNil(usable().unusableReason)
    }

    func testOffIsOffAndSaysWhy() {
        let settings = GuardSettings.off()
        XCTAssertFalse(settings.usable)
        XCTAssertEqual(settings.unusableReason, "the server disabled it for this app")
    }

    /// Every one of these is a server-side mistake, and the log line is all
    /// anybody will have to go on.
    func testEachMissingFieldNamesItself() {
        let noProvider = GuardSettings(enabled: true, provider: nil, publicKey: "key", region: "eu")
        XCTAssertTrue(noProvider.unusableReason!.contains("provider"))

        let noKey = GuardSettings(enabled: true, provider: "s1", publicKey: nil, region: "eu")
        XCTAssertTrue(noKey.unusableReason!.contains("key"))

        let blankKey = GuardSettings(enabled: true, provider: "s1", publicKey: "   ", region: "eu")
        XCTAssertTrue(blankKey.unusableReason!.contains("key"))
    }

    /// Region and endpoint are alternatives. Guessing a default sends somebody
    /// to check a key that was never the problem.
    func testAnEndpointReplacesTheRegionEntirely() {
        let byEndpoint = GuardSettings(
            enabled: true,
            provider: "s1",
            publicKey: "key",
            region: nil,
            endpoint: "https://guard.hertus.io"
        )
        XCTAssertTrue(byEndpoint.usable)

        let neither = GuardSettings(enabled: true, provider: "s1", publicKey: "key")
        XCTAssertTrue(neither.unusableReason!.contains("region"))
        XCTAssertTrue(neither.unusableReason!.contains("endpoint"))
    }

    func testTheDefaultTimeoutIsTheDocumentedOne() {
        XCTAssertEqual(GuardSettings.defaultIdentifyTimeoutMs, 8_000)
        XCTAssertEqual(usable().identifyTimeoutMs, 8_000)
    }
}

// MARK: the registry

final class SignalEngineFactoryTests: XCTestCase {

    private var factory = SignalEngineFactory()

    override func setUp() {
        super.setUp()
        factory = SignalEngineFactory()
    }

    func testAnUnregisteredProviderIsNotKnown() {
        XCTAssertFalse(factory.knows("s1"))
        XCTAssertFalse(factory.knows(nil))
    }

    func testARegisteredProviderIsKnownAndConstructed() {
        factory.register(provider: "s1") { FakeSignalEngine() }

        XCTAssertTrue(factory.knows("s1"))
        XCTAssertTrue(factory.create("s1") is FakeSignalEngine)
    }

    /// An unknown provider and a missing registration mean the same thing
    /// upstream: Guard produces nothing and the SDK carries on.
    func testAnUnknownProviderYieldsTheNoopEngineRatherThanNil() {
        factory.register(provider: "s1") { FakeSignalEngine() }

        XCTAssertTrue(factory.create("s2") is NoopSignalEngine)
        XCTAssertTrue(factory.create(nil) is NoopSignalEngine)
    }

    /// A host app calling enable() twice is harmless, not an error a
    /// measurement library has any business raising.
    func testRegisteringTwiceReplacesRatherThanFails() {
        factory.register(provider: "s1") { NoopSignalEngine() }
        factory.register(provider: "s1") { FakeSignalEngine() }

        XCTAssertTrue(factory.create("s1") is FakeSignalEngine)
    }

    func testEachCreateProducesAFreshEngine() {
        factory.register(provider: "s1") { FakeSignalEngine() }

        let first = factory.create("s1")
        let second = factory.create("s1")
        XCTAssertFalse(first === second)
    }

    func testResetForgetsEverything() {
        factory.register(provider: "s1") { FakeSignalEngine() }
        factory.reset()

        XCTAssertFalse(factory.knows("s1"))
    }
}

// MARK: orchestration

final class GuardOrchestrationTests: XCTestCase {

    private var factory = SignalEngineFactory()
    private var lines: [String] = []

    private var log: Logger {
        recordingLogger { [weak self] line in self?.lines.append(line) }
    }

    override func setUp() {
        super.setUp()
        factory = SignalEngineFactory()
        lines = []
    }

    private func makeGuard() -> HertusGuard {
        HertusGuard(log: log, factory: factory, now: { 0 })
    }

    private func usableSettings(
        endpoint: String? = nil,
        sealed: Bool = true
    ) -> GuardSettings {
        GuardSettings(
            enabled: true,
            provider: "s1",
            publicKey: "key",
            region: "eu",
            endpoint: endpoint,
            sealedResults: sealed
        )
    }

    private func start(
        _ subject: HertusGuard,
        settings: GuardSettings,
        clientEnabled: Bool = true,
        guardInSandbox: Bool = true,
        environment: HertusEnvironment = .sandbox
    ) {
        subject.start(
            settings: settings,
            clientEnabled: clientEnabled,
            guardInSandbox: guardInSandbox,
            environment: environment,
            sdkVersion: "1.0.0"
        )
    }

    func testAUsableConfigurationStartsTheEngine() {
        let engine = FakeSignalEngine()
        factory.register(provider: "s1") { engine }

        let subject = makeGuard()
        start(subject, settings: usableSettings())

        XCTAssertTrue(subject.isRunning)
        XCTAssertEqual(engine.startedWith?.publicKey, "key")
        XCTAssertEqual(engine.startedWith?.region, "eu")
        XCTAssertEqual(engine.startedWith?.sdkVersion, "1.0.0")
    }

    func testNoRegisteredEngineLeavesGuardOffAndSaysSo() {
        let subject = makeGuard()
        start(subject, settings: usableSettings())

        XCTAssertFalse(subject.isRunning)
        XCTAssertTrue(lines.contains { $0.contains("no engine for provider 's1'") })
    }

    func testAnUnusableConfigurationLeavesGuardOff() {
        factory.register(provider: "s1") { FakeSignalEngine() }

        let subject = makeGuard()
        start(subject, settings: GuardSettings(enabled: true, provider: "s1", publicKey: nil, region: "eu"))

        XCTAssertFalse(subject.isRunning)
        XCTAssertTrue(lines.contains { $0.contains("guard off") && $0.contains("key") })
    }

    func testTheClientSwitchIsCheckedBeforeAnEngineIsConstructed() {
        var constructed = 0
        factory.register(provider: "s1") {
            constructed += 1
            return FakeSignalEngine()
        }

        let subject = makeGuard()
        start(subject, settings: usableSettings(), clientEnabled: false)

        XCTAssertFalse(subject.isRunning)
        XCTAssertEqual(constructed, 0, "a device that will never identify must not build an engine")
    }

    /// Identification through the vendor is worse than through our proxy, and
    /// much better than none.
    func testARefusedEndpointFallsBackToTheEngineDefault() {
        let engine = FakeSignalEngine()
        factory.register(provider: "s1") { engine }

        let subject = makeGuard()
        start(subject, settings: usableSettings(endpoint: "http://evil.example.com"), environment: .production)

        XCTAssertTrue(subject.isRunning)
        XCTAssertNil(engine.startedWith?.endpoint)
        XCTAssertTrue(lines.contains { $0.contains("endpoint was refused") })
    }

    func testAnAcceptableEndpointReachesTheEngine() {
        let engine = FakeSignalEngine()
        factory.register(provider: "s1") { engine }

        let subject = makeGuard()
        start(subject, settings: usableSettings(endpoint: "https://guard.hertus.io"), environment: .production)

        XCTAssertEqual(engine.startedWith?.endpoint, "https://guard.hertus.io")
    }

    func testStartingAgainShutsTheOldEngineDown() {
        let engine = FakeSignalEngine()
        factory.register(provider: "s1") { engine }

        let subject = makeGuard()
        start(subject, settings: usableSettings())
        start(subject, settings: usableSettings())

        XCTAssertEqual(engine.shutdownCount, 1)
    }

    // MARK: identify

    /// A caller must not have to distinguish "off" from "broken" by inspecting
    /// an error it then ignores.
    func testIdentifyOnAStoppedGuardIsDisabledAndNotAnError() {
        var received: (GuardSignal?, HertusError?)?
        makeGuard().identify { signal, error, _ in received = (signal, error) }

        XCTAssertEqual(received?.0?.source, .disabled)
        XCTAssertNil(received?.1, "a configuration state is not a failure")
    }

    func testASuccessfulIdentifyPassesTheSignalThrough() {
        let signal = GuardSignal(
            sealedPayload: "sealed",
            requestId: "req",
            confidence: 0.97,
            source: .engine
        )
        factory.register(provider: "s1") { FakeSignalEngine(signal: signal) }

        let subject = makeGuard()
        start(subject, settings: usableSettings())

        var received: GuardSignal?
        subject.identify { signal, _, _ in received = signal }

        XCTAssertEqual(received?.sealedPayload, "sealed")
        XCTAssertEqual(received?.confidence, 0.97)
        XCTAssertTrue(received?.identified == true)
    }

    func testTheConfiguredTimeoutReachesTheEngine() {
        let engine = FakeSignalEngine()
        factory.register(provider: "s1") { engine }

        let subject = makeGuard()
        start(
            subject,
            settings: GuardSettings(
                enabled: true,
                provider: "s1",
                publicKey: "key",
                region: "eu",
                identifyTimeoutMs: 1_234
            )
        )
        subject.identify { _, _, _ in }

        XCTAssertEqual(engine.lastTimeoutMs, 1_234)
    }

    /// An engine that answers with neither a signal nor an error has broken its
    /// contract. Nothing downstream should have to handle a nil-nil pair.
    func testAnEngineThatAnswersNothingIsNormalised() {
        factory.register(provider: "s1") { FakeSignalEngine() }

        let subject = makeGuard()
        start(subject, settings: usableSettings())

        var received: HertusError?
        subject.identify { _, error, _ in received = error }

        XCTAssertEqual(received?.code, .guardResponseInvalid)
    }

    func testAnEngineErrorIsPassedThroughUnchanged() {
        factory.register(provider: "s1") {
            FakeSignalEngine(error: HertusError(code: .guardQuota))
        }

        let subject = makeGuard()
        start(subject, settings: usableSettings())

        var received: HertusError?
        subject.identify { _, error, _ in received = error }

        XCTAssertEqual(received?.code, .guardQuota)
    }

    func testShutdownStopsTheEngineAndGuardAnswersDisabledAgain() {
        let engine = FakeSignalEngine(signal: GuardSignal.none())
        factory.register(provider: "s1") { engine }

        let subject = makeGuard()
        start(subject, settings: usableSettings())
        subject.shutdown()

        XCTAssertFalse(subject.isRunning)
        XCTAssertEqual(engine.shutdownCount, 1)

        var received: GuardSignal?
        subject.identify { signal, _, _ in received = signal }
        XCTAssertEqual(received?.source, .disabled)
    }

    // MARK: what may be said

    /// The single channel by which a vendor's wording may reach a console, and
    /// it does not exist in production builds.
    func testTheEngineDiagnosticIsLoggedAtVerboseOnly() {
        factory.register(provider: "s1") {
            FakeSignalEngine(signal: GuardSignal.none(), diagnostic: "vendor specific wording")
        }

        var verboseLines: [String] = []
        let verbose = HertusGuard(
            log: Logger(level: .verbose, environment: .sandbox) { _, message in
                verboseLines.append(message)
            },
            factory: factory,
            now: { 0 }
        )
        verbose.start(
            settings: usableSettings(),
            clientEnabled: true,
            guardInSandbox: true,
            environment: .sandbox,
            sdkVersion: "1.0.0"
        )
        verbose.identify { _, _, _ in }
        XCTAssertTrue(verboseLines.contains { $0.contains("vendor specific wording") })

        var productionLines: [String] = []
        let production = HertusGuard(
            log: Logger(level: .verbose, environment: .production) { _, message in
                productionLines.append(message)
            },
            factory: factory,
            now: { 0 }
        )
        production.start(
            settings: usableSettings(),
            clientEnabled: true,
            guardInSandbox: false,
            environment: .production,
            sdkVersion: "1.0.0"
        )
        production.identify { _, _, _ in }
        XCTAssertFalse(
            productionLines.contains { $0.contains("vendor specific wording") },
            "verbose is clamped in production, so vendor wording cannot reach a console"
        )
    }

    /// A description ends up in a log line somebody pastes into a support
    /// ticket, and the sealed payload is a bearer token until the server pins
    /// it against replay.
    func testASignalDescriptionHidesTheSealedPayload() {
        let signal = GuardSignal(
            sealedPayload: "super-secret-blob",
            requestId: "req-12345",
            confidence: 0.5,
            source: .engine
        )

        XCTAssertFalse(signal.description.contains("super-secret-blob"))
        XCTAssertFalse(signal.description.contains("req-12345"))
        XCTAssertTrue(signal.description.contains("present"))
    }
}

// MARK: logging rules

final class LoggerTests: XCTestCase {

    private func captured(level: HertusLogLevel, environment: HertusEnvironment) -> [String] {
        var lines: [String] = []
        let log = Logger(level: level, environment: environment) { _, message in lines.append(message) }
        log.v("verbose")
        log.d("debug")
        log.i("info")
        log.w("warn")
        log.e("error")
        return lines
    }

    func testTheThresholdIsInclusiveAndOrdered() {
        XCTAssertEqual(captured(level: .warn, environment: .sandbox), ["warn", "error"])
        XCTAssertEqual(captured(level: .verbose, environment: .sandbox).count, 5)
    }

    func testSuppressSaysNothingAtAll() {
        XCTAssertTrue(captured(level: .suppress, environment: .sandbox).isEmpty)
    }

    /// Verbose is the only level allowed to carry text from outside the SDK, so
    /// it must not exist in production whatever the host app asked for.
    func testVerboseIsClampedInProduction() {
        let lines = captured(level: .verbose, environment: .production)

        XCTAssertFalse(lines.contains("verbose"))
        XCTAssertTrue(lines.contains("debug"))
    }

    func testVerboseSurvivesInSandbox() {
        XCTAssertTrue(captured(level: .verbose, environment: .sandbox).contains("verbose"))
    }
}
