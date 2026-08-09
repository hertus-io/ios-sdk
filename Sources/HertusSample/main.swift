import Foundation
import Hertus

// A sample that runs anywhere a Swift toolchain does, including a machine with
// no simulator and no Mac.
//
// It exercises what the SDK actually has today: the event model, the validation
// rules, the wire format, and the configuration policy. It makes no network
// call and starts no engine, because neither exists yet. See the closing
// section, which says so on the console rather than leaving it to be
// discovered.
//
// A SwiftUI sample lands with `Hertus.initialize` and `Hertus.track`. Writing
// one now would mean shipping a screen whose buttons do nothing.

// MARK: printing

func section(_ title: String) {
    print("")
    print("=== \(title) ".padding(toLength: 72, withPad: "=", startingAt: 0))
}

func show(_ event: HertusEvent) {
    print("")
    print("  \(event)")
    print("  well formed: \(event.isWellFormed)")

    for rejection in event.rejections {
        print("  refused:     \(rejection)")
    }

    let envelope = event.envelope(
        eventId: UUID().uuidString,
        occurredAtMillis: Int64(Date().timeIntervalSince1970 * 1000)
    )

    guard
        let data = try? JSONSerialization.data(
            withJSONObject: abbreviated(envelope.jsonObject()),
            options: [.prettyPrinted, .sortedKeys]
        ),
        let text = String(data: data, encoding: .utf8)
    else {
        print("  the envelope did not serialize, which should be impossible")
        return
    }

    print(text.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n"))
}

/// Shortens long strings for the console only.
///
/// A store receipt is several kilobytes and would bury everything else here.
/// The real envelope carries it whole, which is the point of the exemption, so
/// this reports the length rather than pretending the value was truncated.
func abbreviated(_ object: [String: Any]) -> [String: Any] {
    guard var parameters = object[EventEnvelope.fieldParameters] as? [String: Any] else {
        return object
    }

    for (key, value) in parameters {
        if let text = value as? String, text.count > 64 {
            parameters[key] = "<\(text.count) characters, sent whole>"
        }
    }

    var copy = object
    copy[EventEnvelope.fieldParameters] = parameters
    return copy
}

// MARK: the SDK

section("SDK")
print("  version:  \(Hertus.sdkVersion())")
print("  platform: \(Hertus.platform())")

// MARK: typed events

section("Typed events")
print("""
  Each of these is a class with named, typed parameters. Every one of them
  serializes to the same envelope: a name and a map. Nothing downstream can
  tell which class produced it, which is what lets a new event type ship
  without touching a bridge.
""")

show(
    RevenueEvent(
        amount: 4.99,
        currency: "USD",
        productId: "pro_monthly"
    )
)

show(
    PurchaseEvent(
        productId: "pro_monthly",
        amount: 4.99,
        currency: "USD",
        transactionId: "2000000123456789",
        receipt: String(repeating: "receiptdata", count: 400)
    )
)

show(
    SubscriptionEvent(
        productId: "pro_annual",
        amount: 39.99,
        currency: "USD",
        transactionId: "2000000987654321",
        periodDays: 365
    )
)

show(
    AdRevenueEvent(
        source: "applovin_max",
        amount: 0.0031,
        currency: "USD",
        network: "meta",
        placement: "rewarded_end"
    )
)

// MARK: the escape hatch

section("Custom events")
print("""
  The escape hatch, and the one most apps use most. Everything the typed
  classes do could be done with this.
""")

show(
    CustomEvent("level_complete") {
        $0.put("level", 12)
        $0.put("duration_seconds", 94.5)
        $0.put("used_hint", false)
        $0.put("world", "forest")
    }
)

// MARK: validation

section("Validation refuses values, never events")
print("""
  A malformed figure is worth less than the fact that something happened, and
  throwing here would put the SDK in a host app's crash reports. Each of these
  loses the bad parameter and keeps the event.
""")

print("\n  lowercase currency, which is the most common mistake:")
show(RevenueEvent(amount: 4.99, currency: "usd"))

print("\n  a negative amount, which is usually a refund reported the wrong way:")
show(RevenueEvent(amount: -10.0, currency: "USD"))

print("\n  a value with no JSON form:")
show(CustomEvent("telemetry") { $0.put("ratio", Double.nan) })

print("\n  an event name the reports cannot use:")
show(CustomEvent("not a valid name") { $0.put("kept", true) })

// MARK: configuration

section("Configuration policy")

var config = HertusConfig(appToken: "sk_sandbox_" + String(repeating: "a", count: 64))
config.logLevel = .debug
config.delayStartSeconds = 99

print("  token well formed:  \(config.hasWellFormedToken)")
print("  environment:        \(config.resolvedEnvironment.wireValue), read from the prefix")
print("  delayStart 99s becomes \(config.delayStartMillis)ms, because it is clamped")

// The secret half without its prefix. Refused rather than assumed to be
// production: a bare token means a build predating the prefix, and guessing an
// environment for it is exactly what the prefix exists to stop.
let bare = HertusConfig(appToken: String(repeating: "a", count: 64))
print("  a token with no prefix: well formed = \(bare.hasWellFormedToken)")

var wrong = HertusConfig(appToken: "not-a-token")
wrong.serverUrl = "http://example.com"
print("  a pasted token that is not a token: well formed = \(wrong.hasWellFormedToken)")

print("""

  A config is a struct, so the copy the SDK is handed cannot be edited from
  under it. That is why the iOS SDK needs no snapshot where the Android one
  does.
""")

// MARK: startup

section("Startup, and who decides whether Guard runs")
print("""
  A host app calls initialize and nothing else. Guard finds its engine at
  runtime and decides whether to run it from guardEnabled, the environment
  and the server's answer, in that order.

  Below, the same config in two environments, with the settings the server
  would send held constant. Nothing about the calling code changes.
""")

/// Answers instantly with a configuration, standing in for the server.
///
/// The real source reads the cache and then talks to the server, which is not
/// something a console sample should do.
final class SampleConfigurationSource: ConfigurationSource {
    func start(listener: ConfigurationListener) {
        listener.configurationReady(
            BootstrapConfig(
                configVersion: "sample",
                ttlSeconds: 3_600,
                guardSettings: GuardSettings(
                    enabled: true,
                    provider: "s1",
                    publicKey: "key",
                    region: "eu"
                )
            )
        )
    }
}

/// Stands in for the real adapter, which needs an Apple binary this host does
/// not have. It answers instantly and identifies nothing, which is enough to
/// show which switch stopped it.
final class SampleEngine: SignalEngine {
    func start(config: GuardConfig) {}

    func identify(timeoutMs: Int64, handler: @escaping EngineResultHandler) {
        handler(GuardSignal(sealedPayload: "sample", requestId: "req", confidence: 0.9, source: .engine), nil, nil)
    }

    func shutdown() {}
}

func describeStartup(
    _ label: String,
    environment: HertusEnvironment,
    guardEnabled: Bool = true,
    guardInSandbox: Bool = false
) {
    // A local registry, so the sample cannot disturb the shared one.
    let factory = SignalEngineFactory()
    factory.register(provider: "s1") { SampleEngine() }

    let runtime = HertusRuntime(
        factory: factory,
        makeSource: { _, _, _ in SampleConfigurationSource() },
        schedule: { $0() },
        deliver: { $0() }
    )

    // The environment is chosen by picking a token, because that is now the
    // only way to choose one.
    let prefix = environment == .sandbox ? "sk_sandbox_" : "sk_prod_"
    var config = HertusConfig(appToken: prefix + String(repeating: "a", count: 64))
    config.guardEnabled = guardEnabled
    config.guardInSandbox = guardInSandbox
    config.logLevel = .suppress

    var identified = false
    config.onGuardSignal = { didIdentify, _, _ in identified = didIdentify }

    runtime.initialize(config)

    print(
        "  " + label.padding(toLength: 34, withPad: " ", startingAt: 0)
            + "state=" + "\(runtime.state)".padding(toLength: 10, withPad: " ", startingAt: 0)
            + "guard=" + (runtime.isGuardRunning ? "on " : "off")
            + "  identified=\(identified)"
    )
}

print("")
describeStartup("production", environment: .production)
describeStartup("production, guardEnabled = false", environment: .production, guardEnabled: false)
describeStartup("sandbox", environment: .sandbox)
describeStartup("sandbox, guardInSandbox = true", environment: .sandbox, guardInSandbox: true)

print("""

  Guard is off in sandbox because everything it exists to flag, a simulator,
  a VPN, a reset advertising identifier, also describes a developer testing
  an integration. It reports no signal there rather than an error, because a
  configuration state is not a failure: the SDK still reached ready, still
  measures, and raised no error in any of the four rows.

  The engine above is a stand-in registered by this sample. A real host app
  registers nothing: it adds the HertusGuardS1 library to its target and the
  factory finds the adapter through the Objective-C runtime.
""")

// MARK: what is not here

section("What this sample deliberately does not do")
print("""
  No network call was made. Bootstrap does not exist yet, so the settings
  above came from a stub standing in for it.

  Still to come, in this order:
    1. bootstrap        fetch configuration, cache it, retry with backoff
    2. ingest           sessions, installs, and the events printed above

  Everything shown here is covered by `swift test`. Nothing here needs a Mac.
""")
print("")
