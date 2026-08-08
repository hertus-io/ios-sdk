import Foundation

/// The configuration the server handed back, parsed.
///
/// See docs/SDK.md for the wire contract. The field names follow the contract
/// rather than the engine, so that replacing the engine is not a rename:
/// `GuardSettings.publicKey`, not any vendor's word for it.
public struct BootstrapConfig: Equatable {

    /// Five minutes.
    ///
    /// Below this a misconfigured server turns every cold start into a round
    /// trip, on every device, permanently. The client refuses rather than
    /// cooperating: the server chooses the TTL, but not one that is
    /// operationally absurd.
    public static let minTtlSeconds: Int64 = 300

    /// A week. Above this a bad configuration becomes effectively permanent.
    public static let maxTtlSeconds: Int64 = 604_800

    /// Used when the server does not say. Six hours.
    public static let defaultTtlSeconds: Int64 = 21_600

    /// How long a cache may be served past its TTL when the network is down.
    ///
    /// Seven days. A stale configuration is worse than a fresh one and much
    /// better than none: the alternative for a device that has been offline
    /// since Tuesday is no measurement at all.
    public static let staleMaxSeconds: Int64 = 604_800

    /// Echoed on the next request to enable the 304 path. Opaque.
    public let configVersion: String?

    /// Already clamped to `minTtlSeconds ... maxTtlSeconds`.
    public let ttlSeconds: Int64

    public let guardSettings: GuardSettings

    public let ingestEnabled: Bool
    public let ingestEndpoint: String?

    public init(
        configVersion: String?,
        ttlSeconds: Int64,
        guardSettings: GuardSettings,
        ingestEnabled: Bool = false,
        ingestEndpoint: String? = nil
    ) {
        self.configVersion = configVersion
        self.ttlSeconds = ttlSeconds
        self.guardSettings = guardSettings
        self.ingestEnabled = ingestEnabled
        self.ingestEndpoint = ingestEndpoint
    }
}

/// The diagnostic fields of the bootstrap request.
///
/// Collected once at startup and passed in, rather than read from the platform
/// inside the client, so the client is testable without a device.
///
/// **No device identifiers.** Nothing here is stable across installs or usable
/// to recognise a person. See docs/SDK.md, "Security properties".
public struct DeviceInfo: Equatable {

    public let sdkVersion: String
    public let osVersion: String
    public let bundleId: String
    public let appVersion: String
    public let deviceModel: String
    public let locale: String

    public init(
        sdkVersion: String,
        osVersion: String,
        bundleId: String,
        appVersion: String,
        deviceModel: String,
        locale: String
    ) {
        self.sdkVersion = sdkVersion
        self.osVersion = osVersion
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.deviceModel = deviceModel
        self.locale = locale
    }
}

/// What one bootstrap attempt produced.
public enum BootstrapOutcome {

    /// A configuration to parse and store.
    case fetched(payload: String)

    /// What we already hold is current.
    case notModified

    /// The server refused this token, permanently.
    ///
    /// Terminal by design: a token that is not ours will not become ours by
    /// asking again, and a client that retries a permanent rejection turns one
    /// misconfigured app into a sustained load pattern.
    case rejected(status: Int)

    /// Our fault or the network's. Worth another attempt later.
    case unavailable(reason: String, retryAfterSeconds: Int64? = nil)
}

/// Where a stored configuration lives.
///
/// A protocol so the retry and fallback rules, which are the most consequential
/// code in the SDK, can be driven by a test with no storage on disk.
public protocol ConfigurationStore: AnyObject {

    /// What was stored, or nil if nothing was.
    func read() -> CachedConfiguration?

    func write(payload: String, configVersion: String?, ttlSeconds: Int64)

    /// Marks the stored entry fresh again without rewriting it. The 304 path.
    func touch()

    func clear()
}

/// One attempt at asking the server for a configuration.
///
/// Asynchronous, because the platform's HTTP is. Implementations must call the
/// completion exactly once, and must not call it before returning.
public protocol ConfigurationFetcher: AnyObject {
    func fetch(configVersion: String?, completion: @escaping (BootstrapOutcome) -> Void)
}

/// A stored configuration and how old it is.
public struct CachedConfiguration: Equatable {

    public let payload: String
    public let configVersion: String?
    public let ageSeconds: Int64
    public let ttlSeconds: Int64

    public init(payload: String, configVersion: String?, ageSeconds: Int64, ttlSeconds: Int64) {
        self.payload = payload
        self.configVersion = configVersion
        self.ageSeconds = ageSeconds
        self.ttlSeconds = ttlSeconds
    }

    /// Inside its TTL: usable with no network call at all.
    public var fresh: Bool { ageSeconds < ttlSeconds }

    /// Past half its life. Still served immediately; a refresh runs behind it.
    ///
    /// Refreshing at the halfway point rather than at expiry means the
    /// replacement is fetched while the current one still works, so a device
    /// that is briefly offline at the wrong moment does not fall back to having
    /// nothing.
    public var shouldRevalidate: Bool { ageSeconds >= ttlSeconds / 2 }

    /// Too old to serve even when the network has failed.
    public var expired: Bool { ageSeconds > BootstrapConfig.staleMaxSeconds }
}
