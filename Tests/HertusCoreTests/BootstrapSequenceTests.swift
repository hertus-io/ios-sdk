import XCTest
@testable import HertusCore

/// The retry and fallback rules, driven directly.
///
/// These are the SDK's most consequential decisions and the ones hardest to
/// provoke on a device: a server answering 304 against a cache that is not
/// there, a payload that stops parsing after an upgrade, a network that fails
/// four times and then works. Every one of them is a scripted fetcher here, and
/// every retry runs instantly.
final class BootstrapSequenceTests: XCTestCase {

    // MARK: doubles

    final class FakeStore: ConfigurationStore {
        var entry: CachedConfiguration?
        var writes = 0
        var touches = 0
        var clears = 0

        init(entry: CachedConfiguration? = nil) {
            self.entry = entry
        }

        func read() -> CachedConfiguration? { entry }

        func write(payload: String, configVersion: String?, ttlSeconds: Int64) { writes += 1 }

        func touch() { touches += 1 }

        func clear() {
            clears += 1
            entry = nil
        }
    }

    /// Answers the scripted outcomes in order, then repeats the last forever.
    final class ScriptedFetcher: ConfigurationFetcher {
        private var remaining: [BootstrapOutcome]
        private var last: BootstrapOutcome

        private(set) var validators: [String?] = []
        var calls: Int { validators.count }

        init(_ outcomes: BootstrapOutcome...) {
            remaining = outcomes
            last = outcomes[outcomes.count - 1]
        }

        func fetch(configVersion: String?, completion: @escaping (BootstrapOutcome) -> Void) {
            validators.append(configVersion)
            if !remaining.isEmpty {
                last = remaining.removeFirst()
            }
            completion(last)
        }
    }

    final class RecordingListener: BootstrapSequenceListener {
        var configurations: [BootstrapConfig] = []
        var errors: [HertusErrorCode] = []
        var revalidations: [String?] = []
        var unavailable = 0
        var rejected = 0

        func onConfigurationReady(_ config: BootstrapConfig) { configurations.append(config) }
        func onUnavailable() { unavailable += 1 }
        func onRejected() { rejected += 1 }
        func onRecoverableError(_ code: HertusErrorCode) { errors.append(code) }
        func onRevalidationDue(configVersion: String?) { revalidations.append(configVersion) }
    }

    // MARK: fixtures

    private let listener = RecordingListener()
    private var delays: [Int64] = []

    private let payload = """
    {"configVersion":"cv1","ttlSeconds":3600,"guard":{"enabled":true,"provider":"s1","publicKey":"k","region":"eu"}}
    """

    private func entry(
        ageSeconds: Int64 = 10,
        ttlSeconds: Int64 = 3_600,
        payload: String? = nil,
        configVersion: String? = "cv1"
    ) -> CachedConfiguration {
        CachedConfiguration(
            payload: payload ?? self.payload,
            configVersion: configVersion,
            ageSeconds: ageSeconds,
            ttlSeconds: ttlSeconds
        )
    }

    private func sequence(_ store: FakeStore, _ fetcher: ConfigurationFetcher) -> BootstrapSequence {
        BootstrapSequence(
            cache: store,
            newFetcher: { fetcher },
            log: Logger(level: .suppress, environment: .sandbox) { _, _ in },
            delay: { [self] delayMs, work in
                delays.append(delayMs)
                work()
            },
            listener: listener
        )
    }

    // MARK: cache paths

    func testAFreshCacheIsServedWithoutANetworkCall() {
        let store = FakeStore(entry: entry(ageSeconds: 10, ttlSeconds: 3_600))
        let fetcher = ScriptedFetcher(.unavailable(reason: "should not be called"))

        sequence(store, fetcher).start()

        XCTAssertEqual(listener.configurations.count, 1)
        XCTAssertEqual(fetcher.calls, 0, "a fresh cache must cost no network")
        XCTAssertTrue(listener.revalidations.isEmpty)
    }

    /// Refreshing at the halfway point means the replacement is fetched while
    /// the current one still works.
    func testAFreshCachePastHalfItsLifeAsksForARevalidation() {
        let store = FakeStore(entry: entry(ageSeconds: 1_900, ttlSeconds: 3_600))

        sequence(store, ScriptedFetcher(.notModified)).start()

        XCTAssertEqual(listener.configurations.count, 1)
        XCTAssertEqual(listener.revalidations, ["cv1"])
    }

    /// A payload that no longer parses means this build changed its mind about
    /// the contract.
    func testAnUnparseableCacheIsDiscardedAndRefetchedWithoutAValidator() {
        let store = FakeStore(entry: entry(payload: "{ not json"))
        let fetcher = ScriptedFetcher(.fetched(payload: payload))

        sequence(store, fetcher).start()

        XCTAssertEqual(store.clears, 1)
        XCTAssertEqual(fetcher.calls, 1)
        XCTAssertNil(fetcher.validators[0], "a discarded payload must not be validated against")
        XCTAssertEqual(listener.configurations.count, 1)
    }

    // MARK: fetch paths

    func testA200IsParsedCachedAndReported() {
        let store = FakeStore()

        sequence(store, ScriptedFetcher(.fetched(payload: payload))).start()

        XCTAssertEqual(listener.configurations.count, 1)
        XCTAssertEqual(store.writes, 1)
        XCTAssertTrue(delays.isEmpty)
    }

    /// A 200 whose body will not parse must count as an attempt. Without that it
    /// is an unbacked-off loop against a server that is already misbehaving.
    func testAnUnparseable200DoesNotLoopForever() {
        let store = FakeStore()
        let fetcher = ScriptedFetcher(.fetched(payload: "{ not json"))

        sequence(store, fetcher).start()

        XCTAssertEqual(fetcher.calls, Backoff.maxAttempts)
        XCTAssertEqual(delays.count, Backoff.maxAttempts - 1)
        XCTAssertEqual(listener.errors.count, Backoff.maxAttempts)
        XCTAssertTrue(listener.errors.allSatisfy { $0 == .serverUnavailable })
        XCTAssertTrue(listener.configurations.isEmpty)
    }

    func testA304WithAUsableCacheServesIt() {
        let store = FakeStore(entry: entry(ageSeconds: 7_200, ttlSeconds: 3_600))
        let fetcher = ScriptedFetcher(.notModified)

        sequence(store, fetcher).start()

        XCTAssertEqual(listener.configurations.count, 1)
        XCTAssertEqual(store.touches, 1)
        XCTAssertEqual(fetcher.validators, ["cv1"], "the validator should have been sent")
    }

    /// A server answering 304 unconditionally, against a device holding nothing,
    /// must not spin.
    func testA304WithNothingBehindItDoesNotLoopForever() {
        let store = FakeStore()
        let fetcher = ScriptedFetcher(.notModified)

        sequence(store, fetcher).start()

        XCTAssertEqual(fetcher.calls, Backoff.maxAttempts)
        XCTAssertEqual(delays.count, Backoff.maxAttempts - 1)
        XCTAssertTrue(
            fetcher.validators.dropFirst().allSatisfy { $0 == nil },
            "the validator must be dropped after the first 304"
        )
    }

    /// A token that is not ours will not become ours by asking again.
    func testARejectionIsTerminalAndNotRetried() {
        let store = FakeStore()
        let fetcher = ScriptedFetcher(.rejected(status: 401))

        sequence(store, fetcher).start()

        XCTAssertEqual(listener.rejected, 1)
        XCTAssertEqual(fetcher.calls, 1)
        XCTAssertTrue(delays.isEmpty)
        XCTAssertEqual(listener.unavailable, 0)
    }

    // MARK: degradation

    /// The alternative for a device offline since Tuesday is no measurement at
    /// all.
    func testAnUnavailableServerFallsBackToAStaleCache() {
        let store = FakeStore(entry: entry(ageSeconds: 7_200, ttlSeconds: 3_600))
        let fetcher = ScriptedFetcher(.unavailable(reason: "dns"))

        sequence(store, fetcher).start()

        XCTAssertEqual(listener.configurations.count, 1)
        XCTAssertEqual(listener.unavailable, 0, "a served stale cache is not a degradation")
        XCTAssertEqual(fetcher.calls, 1)
    }

    func testACachePastTheStalenessLimitIsNotServed() {
        let store = FakeStore(entry: entry(ageSeconds: BootstrapConfig.staleMaxSeconds + 1, ttlSeconds: 3_600))

        sequence(store, ScriptedFetcher(.unavailable(reason: "dns"))).start()

        XCTAssertTrue(listener.configurations.isEmpty)
        XCTAssertEqual(listener.unavailable, 1)
    }

    /// Retrying five times before telling the host app would leave
    /// onInitialized silent for over a minute on a dead network, during exactly
    /// the situation the SDK exists to survive.
    func testAnUnavailableServerDegradesOnceAndKeepsTryingBehindIt() {
        let store = FakeStore()
        let fetcher = ScriptedFetcher(.unavailable(reason: "timeout"))

        sequence(store, fetcher).start()

        XCTAssertEqual(listener.unavailable, 1, "degradation is announced once, not per attempt")
        XCTAssertEqual(fetcher.calls, Backoff.maxAttempts)
        XCTAssertEqual(delays.count, Backoff.maxAttempts - 1)
    }

    func testALaterSuccessUpgradesTheSdkInPlace() {
        let store = FakeStore()
        let fetcher = ScriptedFetcher(
            .unavailable(reason: "timeout"),
            .unavailable(reason: "timeout"),
            .fetched(payload: payload)
        )

        sequence(store, fetcher).start()

        XCTAssertEqual(listener.unavailable, 1)
        XCTAssertEqual(listener.configurations.count, 1, "the retry behind the degrade must still land")
        XCTAssertEqual(fetcher.calls, 3)
        XCTAssertEqual(store.writes, 1)
    }

    func testTheServersOwnRetryAfterIsHonoured() {
        let store = FakeStore()
        let fetcher = ScriptedFetcher(
            .unavailable(reason: "rate limited", retryAfterSeconds: 7),
            .fetched(payload: payload)
        )

        sequence(store, fetcher).start()

        XCTAssertEqual(delays, [7_000])
    }

    // MARK: revalidation

    func testARevalidated304OnlyTouchesTheCache() {
        let store = FakeStore(entry: entry())

        sequence(store, ScriptedFetcher(.notModified)).revalidate(configVersion: "cv1")

        XCTAssertEqual(store.touches, 1)
        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(listener.configurations.isEmpty, "nothing changed, so Guard must not restart")
    }

    func testAChangedConfigurationIsRewrittenAndRestartsGuard() {
        let store = FakeStore(entry: entry())

        sequence(store, ScriptedFetcher(.fetched(payload: payload))).revalidate(configVersion: "cv1")

        XCTAssertEqual(store.writes, 1)
        XCTAssertEqual(listener.configurations.count, 1)
    }

    /// What is already running stays running, and the cache keeps its age.
    func testAFailedRevalidationChangesNothing() {
        let store = FakeStore(entry: entry())

        sequence(store, ScriptedFetcher(.unavailable(reason: "dns"))).revalidate(configVersion: "cv1")

        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.touches, 0)
        XCTAssertTrue(listener.configurations.isEmpty)
        XCTAssertEqual(listener.unavailable, 0, "a background refresh must not degrade a working SDK")
    }

    func testAnUnparseableRevalidationIsIgnoredRatherThanCached() {
        let store = FakeStore(entry: entry())

        sequence(store, ScriptedFetcher(.fetched(payload: "{ not json"))).revalidate(configVersion: "cv1")

        XCTAssertEqual(store.writes, 0)
        XCTAssertTrue(listener.configurations.isEmpty)
        XCTAssertTrue(listener.errors.isEmpty)
    }
}
