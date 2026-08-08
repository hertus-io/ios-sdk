import XCTest
@testable import HertusCore
import HertusGuardS1

/// The adapter's contract when the identification engine is not in this build.
///
/// That is the case on every host without an Apple SDK, including the one these
/// tests usually run on, so this is the half of the adapter that can be
/// verified anywhere. The other half needs a Mac and the vendor dependency.
final class GuardAdapterTests: XCTestCase {

    private var factory = SignalEngineFactory()

    override func setUp() {
        super.setUp()
        factory = SignalEngineFactory()
    }

    /// A build with no engine is a supported configuration, not a broken one.
    /// The SDK runs with Guard off rather than failing to start.
    func testEnableReportsWhetherThereWasAnythingToRegister() {
        let registered = HertusGuardS1.enable(into: factory)

        XCTAssertEqual(
            registered,
            HertusGuardS1.isAvailable,
            "enable must agree with isAvailable about whether this build has an engine"
        )
        XCTAssertEqual(factory.canResolve(HertusGuardS1.providerKey), HertusGuardS1.isAvailable)
    }

    /// An integrator who called enable() and still got no Guard has a
    /// dependency problem, and silence would send them to the dashboard.
    func testAnAbsentEngineIsReportedRatherThanHidden() throws {
        try XCTSkipIf(HertusGuardS1.isAvailable, "this build carries the engine")

        XCTAssertFalse(HertusGuardS1.enable(into: factory))
        XCTAssertFalse(factory.canResolve(HertusGuardS1.providerKey))
    }

    /// Guard falls back to the no-op engine rather than nil, so nothing
    /// upstream needs a special case for a build without an adapter.
    func testGuardStaysOffAndUsableWithoutAnEngine() throws {
        try XCTSkipIf(HertusGuardS1.isAvailable, "this build carries the engine")

        HertusGuardS1.enable(into: factory)

        var lines: [String] = []
        let subject = HertusGuard(
            log: Logger(level: .info, environment: .sandbox) { _, message in lines.append(message) },
            factory: factory
        )
        subject.start(
            settings: GuardSettings(
                enabled: true,
                provider: HertusGuardS1.providerKey,
                publicKey: "key",
                region: "eu"
            ),
            clientEnabled: true,
            guardInSandbox: true,
            environment: .sandbox,
            sdkVersion: "1.0.0"
        )

        XCTAssertFalse(subject.isRunning)
        XCTAssertTrue(lines.contains { $0.contains("no engine for provider") })

        var received: GuardSignal?
        subject.identify { signal, _, _ in received = signal }
        XCTAssertEqual(received?.source, .disabled)
    }

    /// The discriminator is the server's, and it must not become the vendor's
    /// name by accident.
    func testTheProviderKeyNamesNobody() {
        XCTAssertEqual(HertusGuardS1.providerKey, "s1")
    }
}
