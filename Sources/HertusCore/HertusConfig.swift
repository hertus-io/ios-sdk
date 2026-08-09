import Foundation

/// Called once when startup finishes, successfully or not.
public typealias HertusInitHandler = (_ ready: Bool) -> Void

/// Called whenever something fails.
public typealias HertusErrorHandler = (_ error: HertusError) -> Void

/// Called when Guard finishes an identification attempt.
///
/// `identified` is false for a switched-off Guard as well as a failed one. The
/// difference is in `error`, which is nil for the former.
public typealias HertusGuardHandler = (_ identified: Bool, _ confidence: Double?, _ error: HertusError?) -> Void

/// Everything the SDK needs from the host app.
///
/// Two required values, everything else defaulted. The shape deliberately
/// matches what the established MMPs commit to, because a developer integrating
/// one of these has almost certainly integrated another and the cost of being
/// different is paid by them.
///
/// ```swift
/// var config = HertusConfig(appToken: Secrets.hertusToken)
/// config.logLevel = .debug
/// Hertus.initialize(config)
/// ```
///
/// There is deliberately no `environment` argument. There used to be, alongside
/// a token that did not say which environment it was for, so a build could hold
/// a production token and declare itself sandbox — and neither the SDK nor the
/// server could tell. The token names its environment now, so the wrong state
/// is unrepresentable rather than merely detectable. Read `resolvedEnvironment`
/// for what the SDK settled on.
///
/// A `struct` rather than a class, which is where this departs from the Android
/// SDK on purpose. There, `HertusConfig` is a mutable object the host app keeps
/// and may edit, so the SDK has to snapshot it at `initialize` to stop a
/// mutation on another thread reconfiguring a running SDK. Value semantics
/// remove that hazard rather than defending against it: what is passed in is
/// already a copy.
public struct HertusConfig {

    /// Long enough to resolve a consent decision, short enough that a host app
    /// cannot use it to defer measurement indefinitely by accident.
    public static let maxDelayStartSeconds: Double = 10

    /// The app's SDK key, from the dashboard. 64 lowercase hex characters.
    ///
    /// Public by construction: it ships inside the app bundle and extracting it
    /// is trivial. It identifies an app; it does not authorise anything. See
    /// docs/SDK.md, "Security properties".
    public var appToken: String

    /// The environment `appToken` names, or `.production` when it names none.
    ///
    /// Production is the safe reading of a token that cannot be parsed: it is
    /// the quieter log level and the one that refuses a cleartext `serverUrl`.
    /// A malformed token stops initialization anyway, so this only governs what
    /// happens while that is being reported.
    public var resolvedEnvironment: HertusEnvironment {
        AppToken.environment(of: appToken) ?? .production
    }

    /// Forced to `.debug` or quieter in `.production`; see `HertusLogLevel`.
    public var logLevel: HertusLogLevel = .info

    /// Hold measurement for this long after `initialize`, so a host app can
    /// finish resolving whatever it needs first, usually a consent decision.
    ///
    /// Clamped to `0...10`. It delays the queue draining, never the
    /// configuration fetch: waiting to ask would make a consent delay into a
    /// cold-start delay for every launch.
    public var delayStartSeconds: Double = 0

    /// The client-side half of Guard's kill switch.
    ///
    /// The server has the other half. Either being false switches Guard off,
    /// and neither can turn it on alone. A customer can disable identification
    /// without waiting for us, and we can disable it without waiting for them.
    public var guardEnabled: Bool = true

    /// Run Guard in `.sandbox` too. Off, and it should stay off for anything
    /// but debugging Guard itself.
    ///
    /// Guard's job is to notice simulators, VPNs, proxies and advertising
    /// identifiers that cannot be real. Every one of those describes a
    /// developer testing an integration, so in sandbox it spends an
    /// identification to report true things about somebody who is not a
    /// fraudster. Worse, the record most likely to be flagged is the
    /// developer's own install, which is the one they are looking for.
    public var guardInSandbox: Bool = false

    /// Point the SDK at a different backend. Nil uses the default for the
    /// environment named by `appToken`.
    ///
    /// An origin (`https://host[:port]`), not a base path: the SDK appends the
    /// versioned API path itself. Cleartext is accepted only when `appToken` is
    /// a `sk_sandbox_` token and the host cannot be reached from the public
    /// internet — so reaching a plain-HTTP server requires holding a sandbox
    /// credential, rather than merely saying so.
    public var serverUrl: String?

    public var onInitialized: HertusInitHandler?
    public var onError: HertusErrorHandler?
    public var onGuardSignal: HertusGuardHandler?

    public init(appToken: String) {
        self.appToken = appToken
    }

    /// `delayStartSeconds` clamped and converted, so a negative or absurd value
    /// cannot hold the queue.
    public var delayStartMillis: Int64 {
        let clamped = min(max(delayStartSeconds, 0), HertusConfig.maxDelayStartSeconds)
        return Int64(clamped * 1000)
    }

    /// Whether the token is the shape the server mints.
    ///
    /// Exposed so a host app can assert on its own build configuration in its
    /// own tests, which is where a token pasted with a trailing newline is
    /// cheapest to catch.
    public var hasWellFormedToken: Bool { AppToken.isWellFormed(appToken) }
}
