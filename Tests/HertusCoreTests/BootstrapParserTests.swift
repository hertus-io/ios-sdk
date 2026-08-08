import XCTest
@testable import HertusCore

/// The parser, against the response shapes the server can produce.
///
/// Several of these the server does not emit today. They are here because the
/// client has to handle them the day it does, and a parser tested only against
/// what is currently sent is a parser that breaks on the first change.
final class BootstrapParserTests: XCTestCase {

    private let happy = """
    {
      "configVersion": "b8c1d2e3f4a5",
      "ttlSeconds": 21600,
      "guard": {
        "enabled": true,
        "provider": "s1",
        "publicKey": "pk_test",
        "region": "eu",
        "endpoint": "https://guard.hertus.io",
        "endpointFallbacks": [],
        "sealedResults": true,
        "extendedResult": false,
        "locationDataEnabled": false,
        "identifyTimeoutMs": 8000
      },
      "ingest": { "enabled": false, "endpoint": null }
    }
    """

    func testTheHappyPathParses() {
        let config = BootstrapParser.parse(happy)

        XCTAssertEqual(config?.configVersion, "b8c1d2e3f4a5")
        XCTAssertEqual(config?.ttlSeconds, 21_600)
        XCTAssertEqual(config?.guardSettings.provider, "s1")
        XCTAssertEqual(config?.guardSettings.publicKey, "pk_test")
        XCTAssertEqual(config?.guardSettings.identifyTimeoutMs, 8_000)
        XCTAssertTrue(config?.guardSettings.sealedResults == true)
        XCTAssertFalse(config?.ingestEnabled == true)
        XCTAssertNil(config?.ingestEndpoint)
    }

    func testAMinimalResponseParses() {
        let config = BootstrapParser.parse("""
        {"configVersion":"m","ttlSeconds":900,"guard":{"enabled":true,"provider":"s1","publicKey":"k","region":"eu"}}
        """)

        XCTAssertEqual(config?.ttlSeconds, 900)
        XCTAssertTrue(config?.guardSettings.usable == true)
    }

    /// A server newer than a client will send things this build has never heard
    /// of. Failing on them would break every old client at once.
    func testUnknownFieldsAreIgnoredRatherThanRejected() {
        let config = BootstrapParser.parse("""
        {
          "configVersion": "future",
          "ttlSeconds": 900,
          "somethingNew": {"nested": [1, 2, 3]},
          "guard": {"enabled": true, "provider": "s1", "publicKey": "k", "region": "eu", "futureFlag": true}
        }
        """)

        XCTAssertNotNil(config)
        XCTAssertEqual(config?.configVersion, "future")
        XCTAssertTrue(config?.guardSettings.usable == true)
    }

    /// A half-written response must produce a working, quieter SDK rather than a
    /// failure on a background queue.
    func testEveryOptionalFieldHasASafeDefault() {
        let config = BootstrapParser.parse("{}")

        XCTAssertNotNil(config)
        XCTAssertNil(config?.configVersion)
        XCTAssertEqual(config?.ttlSeconds, BootstrapConfig.defaultTtlSeconds)
        XCTAssertFalse(config?.guardSettings.enabled == true)
        XCTAssertFalse(config?.ingestEnabled == true)
    }

    /// An SDK that starts identifying devices because a field was missing is
    /// doing something nobody asked it to do.
    func testGuardDefaultsToOffWhenTheBlockIsAbsent() {
        let config = BootstrapParser.parse("{\"ttlSeconds\":900}")

        XCTAssertFalse(config?.guardSettings.enabled == true)
        XCTAssertEqual(config?.guardSettings.unusableReason, "the server disabled it for this app")
    }

    /// The server chooses the TTL, but not one that is operationally absurd.
    func testTheTtlIsClamped() {
        XCTAssertEqual(BootstrapParser.parse("{\"ttlSeconds\":1}")?.ttlSeconds, BootstrapConfig.minTtlSeconds)
        XCTAssertEqual(
            BootstrapParser.parse("{\"ttlSeconds\":99999999}")?.ttlSeconds,
            BootstrapConfig.maxTtlSeconds
        )
        XCTAssertEqual(BootstrapParser.parse("{\"ttlSeconds\":-5}")?.ttlSeconds, BootstrapConfig.minTtlSeconds)
    }

    /// A zero timeout means "never finish"; a ten-minute one means a wedged
    /// launch. Neither is a thing to honour faithfully.
    func testTheIdentifyTimeoutIsClamped() {
        let fast = BootstrapParser.parse("""
        {"guard":{"enabled":true,"provider":"s1","publicKey":"k","region":"eu","identifyTimeoutMs":0}}
        """)
        XCTAssertEqual(fast?.guardSettings.identifyTimeoutMs, BootstrapParser.minIdentifyTimeoutMs)

        let slow = BootstrapParser.parse("""
        {"guard":{"enabled":true,"provider":"s1","publicKey":"k","region":"eu","identifyTimeoutMs":600000}}
        """)
        XCTAssertEqual(slow?.guardSettings.identifyTimeoutMs, BootstrapParser.maxIdentifyTimeoutMs)
    }

    /// A blank key that reached the engine would fail on every launch with an
    /// error pointing at the subscription rather than at the empty field.
    func testJsonNullAndBlankBecomeNilRatherThanText() {
        let config = BootstrapParser.parse("""
        {"configVersion":null,"guard":{"enabled":true,"provider":"s1","publicKey":"   ","region":null}}
        """)

        XCTAssertNil(config?.configVersion)
        XCTAssertNil(config?.guardSettings.publicKey)
        XCTAssertNil(config?.guardSettings.region)
        XCTAssertEqual(config?.guardSettings.unusableReason, "the server sent no key")
    }

    func testEndpointFallbacksSkipRubbish() {
        let config = BootstrapParser.parse("""
        {"guard":{"enabled":true,"provider":"s1","publicKey":"k","endpoint":"https://a.example.com",
        "endpointFallbacks":["https://b.example.com","","   ",42,null]}}
        """)

        XCTAssertEqual(config?.guardSettings.endpointFallbacks, ["https://b.example.com"])
    }

    func testAnUnrecognisedProviderIsCarriedThroughRatherThanRewritten() {
        let config = BootstrapParser.parse("""
        {"guard":{"enabled":true,"provider":"s9","publicKey":"k","region":"eu"}}
        """)

        XCTAssertEqual(config?.guardSettings.provider, "s9")
        XCTAssertTrue(config?.guardSettings.usable == true, "the provider is the factory's problem, not the parser's")
    }

    /// The caller treats this as a server fault, because it is one.
    func testSomethingThatIsNotAnObjectIsRefused() {
        XCTAssertNil(BootstrapParser.parse("not json"))
        XCTAssertNil(BootstrapParser.parse("[1,2,3]"))
        XCTAssertNil(BootstrapParser.parse(""))
        XCTAssertNil(BootstrapParser.parse("{ unterminated"))
    }

    func testIngestIsReadWhenPresent() {
        let config = BootstrapParser.parse("""
        {"ingest":{"enabled":true,"endpoint":"https://ingest.hertus.io"}}
        """)

        XCTAssertTrue(config?.ingestEnabled == true)
        XCTAssertEqual(config?.ingestEndpoint, "https://ingest.hertus.io")
    }
}
