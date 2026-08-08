import Foundation

/// The Guard half of the bootstrap response.
///
/// Every field arrives over the network, so nothing here is trusted: the
/// endpoint is checked by `UrlPolicy` before an engine is pointed at it, and
/// `unusableReason` refuses a configuration that cannot work rather than
/// letting an engine fail on every launch with an error that points at the
/// wrong thing.
public struct GuardSettings: Equatable {

    public static let defaultIdentifyTimeoutMs: Int64 = 8_000

    public let enabled: Bool

    /// Which engine. Opaque; an unrecognised value means Guard does not run.
    public let provider: String?

    public let publicKey: String?
    public let region: String?
    public let endpoint: String?
    public let endpointFallbacks: [String]
    public let sealedResults: Bool
    public let extendedResult: Bool
    public let locationDataEnabled: Bool
    public let identifyTimeoutMs: Int64

    public init(
        enabled: Bool,
        provider: String?,
        publicKey: String?,
        region: String? = nil,
        endpoint: String? = nil,
        endpointFallbacks: [String] = [],
        sealedResults: Bool = false,
        extendedResult: Bool = false,
        locationDataEnabled: Bool = false,
        identifyTimeoutMs: Int64 = GuardSettings.defaultIdentifyTimeoutMs
    ) {
        self.enabled = enabled
        self.provider = provider
        self.publicKey = publicKey
        self.region = region
        self.endpoint = endpoint
        self.endpointFallbacks = endpointFallbacks
        self.sealedResults = sealedResults
        self.extendedResult = extendedResult
        self.locationDataEnabled = locationDataEnabled
        self.identifyTimeoutMs = identifyTimeoutMs
    }

    /// Guard off, for a response with no `guard` object at all.
    public static func off() -> GuardSettings {
        GuardSettings(enabled: false, provider: nil, publicKey: nil)
    }

    /// Why this configuration cannot run an engine, or nil if it can.
    ///
    /// A reason rather than a boolean because every one of these is a
    /// server-side mistake, and the log line is the only thing anybody will
    /// have to go on. "Guard is off" without saying which field was missing
    /// sends somebody reading the wrong dashboard screen.
    public var unusableReason: String? {
        if !enabled { return "the server disabled it for this app" }
        if provider == nil { return "the server named no provider" }
        if publicKey == nil || publicKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            return "the server sent no key"
        }
        // Region and endpoint are alternatives: a configured endpoint replaces
        // the region entirely, so exactly one of them is needed.
        //
        // Guessing a default here is worse than refusing. An engine pointed at
        // the wrong region answers "wrong region", which maps to a credentials
        // error and reads as an expired subscription, sending somebody to check
        // a key that was never the problem. Not knowing where to send a request
        // is not the same as having a bad credential, and it should not look
        // like one.
        if region == nil && endpoint == nil {
            return "the server sent neither a region nor an endpoint"
        }
        return nil
    }

    /// Whether this is enough to actually run an engine.
    public var usable: Bool { unusableReason == nil }
}
