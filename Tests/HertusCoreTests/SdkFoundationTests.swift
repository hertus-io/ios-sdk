import XCTest
@testable import HertusCore

final class SdkStateTests: XCTestCase {

    func testANewHolderIsIdle() {
        XCTAssertEqual(SdkStateHolder().current, .idle)
    }

    func testTheOrdinaryStartupPathIsAllowed() {
        let states = SdkStateHolder()
        XCTAssertTrue(states.move(to: .initializing))
        XCTAssertTrue(states.move(to: .ready))
        XCTAssertEqual(states.current, .ready)
    }

    /// A malformed token disables the SDK before any work is scheduled, so it
    /// never passes through `initializing`.
    func testIdleCanBeDisabledDirectly() {
        let states = SdkStateHolder()
        XCTAssertTrue(states.move(to: .disabled))
        XCTAssertEqual(states.current, .disabled)
    }

    func testIdleCannotJumpStraightToASettledState() {
        let states = SdkStateHolder()
        XCTAssertFalse(states.move(to: .ready))
        XCTAssertFalse(states.move(to: .degraded))
        XCTAssertEqual(states.current, .idle)
    }

    /// The reason `degraded` exists. A retry that succeeds behind an announced
    /// failure upgrades the SDK in place.
    func testDegradedCanBeUpgradedToReady() {
        let states = SdkStateHolder()
        states.move(to: .initializing)
        states.move(to: .degraded)

        XCTAssertTrue(states.move(to: .ready))
        XCTAssertEqual(states.current, .ready)
    }

    func testReadyCannotFallBackToDegraded() {
        let states = SdkStateHolder()
        states.move(to: .initializing)
        states.move(to: .ready)

        XCTAssertFalse(states.move(to: .degraded), "a working SDK must not un-work itself")
        XCTAssertEqual(states.current, .ready)
    }

    func testDisabledIsTerminalFromEveryState() {
        for reached in [SdkState.initializing, .ready, .degraded] {
            let states = SdkStateHolder()
            states.move(to: .initializing)
            if reached != .initializing { states.move(to: reached) }

            XCTAssertTrue(states.move(to: .disabled))
            XCTAssertFalse(states.move(to: .ready))
            XCTAssertFalse(states.move(to: .degraded))
            XCTAssertFalse(states.move(to: .initializing))
            XCTAssertEqual(states.current, .disabled)
        }
    }

    func testOnlyTheSettledStatesAcceptWork() {
        XCTAssertTrue(SdkState.ready.acceptsWork)
        XCTAssertTrue(SdkState.degraded.acceptsWork)
        XCTAssertFalse(SdkState.idle.acceptsWork)
        XCTAssertFalse(SdkState.initializing.acceptsWork)
        XCTAssertFalse(SdkState.disabled.acceptsWork)
    }

    func testQueueingAndAcceptingAreNeverBothTrue() {
        for state in SdkState.allCases {
            XCTAssertFalse(state.queuesWork && state.acceptsWork, "\(state) both queues and runs work")
        }
    }

    func testOnlyDisabledIsTerminal() {
        for state in SdkState.allCases where state != .disabled {
            XCTAssertFalse(state.isTerminal, "\(state) must not be terminal")
        }
        XCTAssertTrue(SdkState.disabled.isTerminal)
    }
}

final class AppTokenTests: XCTestCase {

    private let valid = String(repeating: "a", count: 64)

    func test64LowercaseHexCharactersIsTheShape() {
        XCTAssertTrue(AppToken.isWellFormed(valid))
        XCTAssertTrue(AppToken.isWellFormed(String(repeating: "0123456789abcdef", count: 4)))
    }

    func testTheWrongLengthIsRefused() {
        XCTAssertFalse(AppToken.isWellFormed(String(repeating: "a", count: 63)))
        XCTAssertFalse(AppToken.isWellFormed(String(repeating: "a", count: 65)))
        XCTAssertFalse(AppToken.isWellFormed(""))
    }

    /// The server mints lowercase, so uppercase means the value came from
    /// somewhere else.
    func testUppercaseHexIsRefused() {
        XCTAssertFalse(AppToken.isWellFormed(String(repeating: "A", count: 64)))
    }

    func testNonHexCharactersAreRefused() {
        XCTAssertFalse(AppToken.isWellFormed(String(repeating: "g", count: 64)))
        XCTAssertFalse(AppToken.isWellFormed(String(repeating: "-", count: 64)))
    }

    /// A pasted token often arrives wrapped in whitespace. None of that is a
    /// token.
    func testSurroundingWhitespaceIsNotSilentlyAccepted() {
        XCTAssertFalse(AppToken.isWellFormed(" " + valid))
        XCTAssertFalse(AppToken.isWellFormed(valid + "\n"))
    }

    func testTheFailureMessagePointsAtTheDashboard() {
        XCTAssertTrue(AppToken.malformedMessage.contains("SDK credentials"))
        XCTAssertTrue(AppToken.malformedMessage.contains("64"))
    }

    func testRedactionKeepsOnlyTheTail() {
        let token = String(repeating: "0123456789abcdef", count: 4)
        let redacted = AppToken.redact(token)

        XCTAssertEqual(redacted, "...89abcdef")
        XCTAssertFalse(redacted.contains(token))
    }

    func testRedactingSomethingTooShortRevealsNothing() {
        XCTAssertEqual(AppToken.redact("abc"), "...")
        XCTAssertEqual(AppToken.redact(""), "...")
    }
}

final class ServerEndpointsTests: XCTestCase {

    func testEachEnvironmentHasItsOwnDefault() {
        let production = ServerEndpoints.defaultFor(.production)
        let sandbox = ServerEndpoints.defaultFor(.sandbox)

        XCTAssertTrue(production.hasPrefix("https://"))
        XCTAssertTrue(sandbox.hasPrefix("https://"))
        XCTAssertNotEqual(production, sandbox, "the two environments must not share a host")
    }

    func testNoOverrideMeansTheDefaultAndNoComplaint() {
        let resolved = ServerEndpoints.resolve(override: nil, environment: .production)

        XCTAssertEqual(resolved.url, ServerEndpoints.defaultFor(.production))
        XCTAssertFalse(resolved.refusedOverride)
    }

    func testAnAcceptableOverrideIsUsed() {
        let resolved = ServerEndpoints.resolve(
            override: "https://api.example.com",
            environment: .production
        )

        XCTAssertEqual(resolved.url, "https://api.example.com")
        XCTAssertFalse(resolved.refusedOverride)
    }

    /// Falling back silently would leave a developer pointing the sample app at
    /// their laptop and wondering why the requests went to production.
    func testARefusedOverrideFallsBackAndSaysSo() {
        let resolved = ServerEndpoints.resolve(
            override: "http://example.com",
            environment: .production
        )

        XCTAssertEqual(resolved.url, ServerEndpoints.defaultFor(.production))
        XCTAssertTrue(resolved.refusedOverride)
    }

    func testNonsenseIsRefusedRatherThanPassedThrough() {
        for override in ["", "   ", "not a url", "ftp://example.com", "example.com"] {
            let resolved = ServerEndpoints.resolve(override: override, environment: .sandbox)
            XCTAssertTrue(resolved.refusedOverride, "\(override) should have been refused")
            XCTAssertEqual(resolved.url, ServerEndpoints.defaultFor(.sandbox))
        }
    }

    /// This is how a sample app reaches a server on the developer's machine.
    func testSandboxAcceptsALocalCleartextHost() {
        for host in ["http://localhost:8080", "http://127.0.0.1:8080", "http://192.168.1.10:8080"] {
            let resolved = ServerEndpoints.resolve(override: host, environment: .sandbox)
            XCTAssertFalse(resolved.refusedOverride, "\(host) should have been accepted")
            XCTAssertEqual(resolved.url, host)
        }
    }

    func testProductionRefusesTheSameLocalHost() {
        let resolved = ServerEndpoints.resolve(override: "http://127.0.0.1:8080", environment: .production)
        XCTAssertTrue(resolved.refusedOverride)
    }

    /// The SDK appends the versioned API path itself, so a path here would
    /// produce requests nobody enjoys diagnosing.
    func testAnOverrideIsNormalisedToAnOrigin() {
        let resolved = ServerEndpoints.resolve(
            override: "https://api.example.com/some/path",
            environment: .production
        )

        XCTAssertEqual(resolved.url, "https://api.example.com")
    }

    func testAPublicCleartextHostIsRefusedEvenInSandbox() {
        let resolved = ServerEndpoints.resolve(override: "http://8.8.8.8", environment: .sandbox)
        XCTAssertTrue(resolved.refusedOverride)
    }
}

final class BackoffTests: XCTestCase {

    /// Midpoint generator, so the base is visible without the jitter.
    private let noJitter: (ClosedRange<Int64>) -> Int64 = { _ in 0 }

    func testDelayDoublesPerAttempt() {
        XCTAssertEqual(Backoff.delayMillis(attempt: 1, jitter: noJitter), 1_000)
        XCTAssertEqual(Backoff.delayMillis(attempt: 2, jitter: noJitter), 2_000)
        XCTAssertEqual(Backoff.delayMillis(attempt: 3, jitter: noJitter), 4_000)
        XCTAssertEqual(Backoff.delayMillis(attempt: 4, jitter: noJitter), 8_000)
        XCTAssertEqual(Backoff.delayMillis(attempt: 5, jitter: noJitter), 16_000)
    }

    func testGrowthIsCappedRatherThanUnbounded() {
        XCTAssertEqual(
            Backoff.delayMillis(attempt: 9, jitter: noJitter),
            16_000,
            "attempt 9 must not be 256s"
        )
    }

    /// The part that matters. Every device on a network reconnects at the same
    /// moment when it comes back, so an un-jittered backoff turns one outage
    /// into a synchronised stampede against the server that just recovered.
    func testJitterStaysInsideTwentyPercentAndActuallyVaries() {
        var seen = Set<Int64>()
        for _ in 0..<500 {
            let delay = Backoff.delayMillis(attempt: 3)
            XCTAssertGreaterThanOrEqual(delay, 3_200, "\(delay) below the band")
            XCTAssertLessThanOrEqual(delay, 4_800, "\(delay) above the band")
            seen.insert(delay)
        }
        XCTAssertGreaterThan(seen.count, 1, "500 draws produced one value, so there is no jitter")
    }

    func testRetryAfterWinsOverTheComputedDelay() {
        XCTAssertEqual(Backoff.delayMillis(attempt: 1, retryAfterSeconds: 3), 3_000)
        XCTAssertEqual(Backoff.delayMillis(attempt: 5, retryAfterSeconds: 3), 3_000)
    }

    func testAnAbsurdRetryAfterIsCapped() {
        XCTAssertEqual(
            Backoff.delayMillis(attempt: 1, retryAfterSeconds: 3_600),
            60_000,
            "an hour would strand the SDK for the whole session"
        )
    }

    func testANonsenseRetryAfterFallsBackToTheComputedDelay() {
        let delay = Backoff.delayMillis(attempt: 1, retryAfterSeconds: 0)
        XCTAssertGreaterThanOrEqual(delay, 800, "zero must not mean retry instantly forever")
    }
}

final class HertusConfigTests: XCTestCase {

    private let token = String(repeating: "a", count: 64)

    func testTheDefaultsAreTheDocumentedOnes() {
        let config = HertusConfig(appToken: token, environment: .production)

        XCTAssertEqual(config.logLevel, .info)
        XCTAssertEqual(config.delayStartSeconds, 0)
        XCTAssertTrue(config.guardEnabled)
        XCTAssertFalse(config.guardInSandbox, "sandbox must not identify devices unless asked")
        XCTAssertNil(config.serverUrl)
    }

    func testDelayStartIsClampedRatherThanTrusted() {
        var config = HertusConfig(appToken: token, environment: .sandbox)

        config.delayStartSeconds = -5
        XCTAssertEqual(config.delayStartMillis, 0)

        config.delayStartSeconds = 2.5
        XCTAssertEqual(config.delayStartMillis, 2_500)

        config.delayStartSeconds = 9_999
        XCTAssertEqual(config.delayStartMillis, Int64(HertusConfig.maxDelayStartSeconds * 1000))
    }

    /// Value semantics are why the iOS SDK needs no snapshot: a copy handed to
    /// the SDK cannot be edited from under it.
    func testACopyDoesNotSeeLaterEdits() {
        var original = HertusConfig(appToken: token, environment: .production)
        let copy = original
        original.logLevel = .verbose

        XCTAssertEqual(copy.logLevel, .info)
    }

    func testTokenShapeIsAvailableToAHostAppsOwnTests() {
        XCTAssertTrue(HertusConfig(appToken: token, environment: .production).hasWellFormedToken)
        XCTAssertFalse(HertusConfig(appToken: "nope", environment: .production).hasWellFormedToken)
    }
}

final class ErrorVocabularyTests: XCTestCase {

    /// Load-bearing strings: a developer greps one, a wrapper switches on it,
    /// and a support conversation quotes it. They must match the Android SDK
    /// and `sdk/contract/errors.yaml` exactly.
    func testWireValuesAreKebabCaseAndStable() {
        XCTAssertEqual(HertusErrorCode.configurationInvalid.wireValue, "configuration-invalid")
        XCTAssertEqual(HertusErrorCode.notInitialized.wireValue, "not-initialized")
        XCTAssertEqual(HertusErrorCode.serverRejected.wireValue, "server-rejected")
        XCTAssertEqual(HertusErrorCode.guardResponseInvalid.wireValue, "guard-response-invalid")
        XCTAssertEqual(HertusErrorCode.unsupportedOperation.wireValue, "unsupported-operation")
        XCTAssertEqual(HertusErrorCode.internalError.wireValue, "internal")
    }

    func testEveryCodeRoundTripsThroughItsWireValue() {
        for code in HertusErrorCode.allCases {
            XCTAssertEqual(HertusErrorCode.fromWireValue(code.wireValue), code)
        }
    }

    func testEveryCodeHasItsOwnWireValue() {
        let values = HertusErrorCode.allCases.map(\.wireValue)
        XCTAssertEqual(Set(values).count, values.count)
    }

    func testEveryCodeHasAMessage() {
        for code in HertusErrorCode.allCases {
            XCTAssertFalse(code.message.isEmpty, "\(code) has no message")
        }
    }

    func testAnUnknownWireValueIsNilRatherThanAGuess() {
        XCTAssertNil(HertusErrorCode.fromWireValue("not-a-code"))
        XCTAssertNil(HertusErrorCode.fromWireValue(""))
    }

    func testAnErrorCarriesItsCodesMessage() {
        let error = HertusError(code: .guardTimeout)

        XCTAssertEqual(error.code, .guardTimeout)
        XCTAssertEqual(error.message, HertusErrorCode.guardTimeout.message)
        XCTAssertEqual(error.wireValue, "guard-timeout")
    }

    func testEnvironmentWireValuesMatchTheDashboardKeys() {
        XCTAssertEqual(HertusEnvironment.production.wireValue, "production")
        XCTAssertEqual(HertusEnvironment.sandbox.wireValue, "sandbox")
        XCTAssertEqual(HertusEnvironment.fromWireValue("sandbox"), .sandbox)
        XCTAssertNil(HertusEnvironment.fromWireValue("staging"))
    }

    func testLogLevelsAreOrderedBySeverity() {
        XCTAssertLessThan(HertusLogLevel.verbose, HertusLogLevel.debug)
        XCTAssertLessThan(HertusLogLevel.debug, HertusLogLevel.info)
        XCTAssertLessThan(HertusLogLevel.info, HertusLogLevel.warn)
        XCTAssertLessThan(HertusLogLevel.warn, HertusLogLevel.error)
        XCTAssertLessThan(HertusLogLevel.error, HertusLogLevel.suppress)
    }
}
