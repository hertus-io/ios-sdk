import XCTest
@testable import HertusCore

final class BootstrapCacheTests: XCTestCase {

    private var defaults: UserDefaults!
    private var clock: Int64 = 1_000_000

    private let payload = "{\"configVersion\":\"cv1\"}"

    override func setUp() {
        super.setUp()
        // A suite of its own, so one test cannot see another's entries and
        // nothing lands in the real defaults.
        let name = "hertus.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)
        clock = 1_000_000
    }

    private func makeCache(
        appToken: String = String(repeating: "a", count: 64),
        environment: HertusEnvironment = .production
    ) -> BootstrapCache {
        BootstrapCache(
            appToken: appToken,
            environment: environment,
            defaults: defaults,
            now: { [weak self] in self?.clock ?? 0 }
        )
    }

    func testAnEmptyCacheReadsAsNothing() {
        XCTAssertNil(makeCache().read())
    }

    func testWhatIsWrittenComesBack() {
        let cache = makeCache()
        cache.write(payload: payload, configVersion: "cv1", ttlSeconds: 3_600)

        let entry = cache.read()
        XCTAssertEqual(entry?.payload, payload)
        XCTAssertEqual(entry?.configVersion, "cv1")
        XCTAssertEqual(entry?.ttlSeconds, 3_600)
        XCTAssertEqual(entry?.ageSeconds, 0)
    }

    func testAgeIsMeasuredFromTheWrite() {
        let cache = makeCache()
        cache.write(payload: payload, configVersion: "cv1", ttlSeconds: 3_600)

        clock += 120_000
        XCTAssertEqual(cache.read()?.ageSeconds, 120)
    }

    /// The 304 path: the server confirmed what we hold is current, so the clock
    /// restarts and the payload is not rewritten.
    func testTouchRestartsTheClockWithoutRewriting() {
        let cache = makeCache()
        cache.write(payload: payload, configVersion: "cv1", ttlSeconds: 3_600)

        clock += 600_000
        XCTAssertEqual(cache.read()?.ageSeconds, 600)

        cache.touch()
        XCTAssertEqual(cache.read()?.ageSeconds, 0)
        XCTAssertEqual(cache.read()?.payload, payload, "touch must not disturb the payload")
        XCTAssertEqual(cache.read()?.configVersion, "cv1")
    }

    func testClearRemovesEverything() {
        let cache = makeCache()
        cache.write(payload: payload, configVersion: "cv1", ttlSeconds: 3_600)
        cache.clear()

        XCTAssertNil(cache.read())
    }

    /// A clock that moved backwards, a timezone change or an NTP correction,
    /// would otherwise make an entry look arbitrarily fresh.
    func testAClockThatWentBackwardsInvalidatesTheEntry() {
        let cache = makeCache()
        cache.write(payload: payload, configVersion: "cv1", ttlSeconds: 3_600)

        clock -= 60_000
        XCTAssertNil(cache.read(), "a negative age is not a fresh cache")
    }

    /// Rotating the SDK key means the old entry is simply never read again.
    func testADifferentTokenSeesADifferentEntry() {
        let first = makeCache(appToken: String(repeating: "a", count: 64))
        first.write(payload: payload, configVersion: "cv1", ttlSeconds: 3_600)

        let second = makeCache(appToken: String(repeating: "b", count: 64))
        XCTAssertNil(second.read())
        XCTAssertNotNil(first.read(), "the original entry must survive")
    }

    /// A build switched from sandbox to production must not serve the other
    /// environment's answer out of a cache that outlived the change.
    func testADifferentEnvironmentSeesADifferentEntry() {
        let production = makeCache(environment: .production)
        production.write(payload: payload, configVersion: "cv1", ttlSeconds: 3_600)

        XCTAssertNil(makeCache(environment: .sandbox).read())
    }

    /// A token in a key is a token in every bug report that includes a defaults
    /// dump.
    func testTheKeyDoesNotContainTheToken() {
        let token = String(repeating: "a", count: 64)
        let key = BootstrapCache.cacheKey(token, .production)

        XCTAssertFalse(key.contains(token))
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(key, BootstrapCache.cacheKey(token, .production), "the key must be stable")
        XCTAssertNotEqual(key, BootstrapCache.cacheKey(token, .sandbox))
    }

    // MARK: the age rules

    func testFreshnessFollowsTheTtl() {
        let fresh = CachedConfiguration(payload: "{}", configVersion: nil, ageSeconds: 10, ttlSeconds: 3_600)
        XCTAssertTrue(fresh.fresh)
        XCTAssertFalse(fresh.shouldRevalidate)

        let halfway = CachedConfiguration(payload: "{}", configVersion: nil, ageSeconds: 1_800, ttlSeconds: 3_600)
        XCTAssertTrue(halfway.fresh)
        XCTAssertTrue(halfway.shouldRevalidate, "past half its life it refreshes behind itself")

        let old = CachedConfiguration(payload: "{}", configVersion: nil, ageSeconds: 4_000, ttlSeconds: 3_600)
        XCTAssertFalse(old.fresh)
        XCTAssertFalse(old.expired, "past its TTL is still servable when the network is down")
    }

    func testExpiryIsTheStalenessLimitRatherThanTheTtl() {
        let stale = CachedConfiguration(
            payload: "{}",
            configVersion: nil,
            ageSeconds: BootstrapConfig.staleMaxSeconds + 1,
            ttlSeconds: 3_600
        )

        XCTAssertTrue(stale.expired)
    }
}
