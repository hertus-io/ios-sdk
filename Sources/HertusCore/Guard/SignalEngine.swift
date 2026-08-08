import Foundation

/// The seam between Hertus and whatever actually identifies a device.
///
/// One protocol, one conformance per engine, and exactly one target in the
/// package that imports an engine's types. Everything above this line is
/// written as though device identification were a solved local problem, which
/// makes swapping the engine, running two, or shipping none of them a change to
/// one target rather than a change everywhere.
///
/// Conformances must be safe to call from a single background queue and must
/// never throw: a failure is a `HertusError` handed to the handler.
public protocol SignalEngine: AnyObject {

    /// Prepares the engine. Idempotent: called again with the same config it
    /// does nothing, called with a different one it reconfigures.
    func start(config: GuardConfig)

    /// Attempts one identification.
    ///
    /// Must call `handler` exactly once, including on timeout, and must not
    /// block the calling queue waiting for the network.
    func identify(timeoutMs: Int64, handler: @escaping EngineResultHandler)

    /// Releases whatever `start` acquired.
    func shutdown()
}

/// How an engine reports one attempt.
///
/// - Parameters:
///   - signal: what identification produced, or nil if it produced nothing.
///   - error: why, or nil on success.
///   - diagnostic: the engine's **own** description of what happened. Logged at
///     verbose and nowhere else, and never copied into `error`. It is the one
///     channel by which a vendor's wording is allowed to reach a developer's
///     console, and it does not exist in production builds.
public typealias EngineResultHandler = (
    _ signal: GuardSignal?,
    _ error: HertusError?,
    _ diagnostic: String?
) -> Void

/// Where a `GuardSignal` came from.
public enum GuardSource {
    /// An engine ran and answered.
    case engine

    /// No engine is present in this build.
    case none

    /// An engine is present but Guard is switched off.
    case disabled
}

/// What Guard hands back, and the complete list of what leaves the engine.
///
/// **The device identifier is deliberately absent.** The engine computes one;
/// nothing here reads it. Two reasons, the second being the one that matters:
///
/// - Nothing on the device makes a decision with it, so holding it only creates
///   something to leak.
/// - `sealedPayload` cannot be forged and an identifier trivially can. The blob
///   is encrypted by the engine's own infrastructure with a key only the Hertus
///   server holds, so a modified app can replay one but cannot invent one. An
///   SDK that read an identifier and posted it would be asking the server to
///   trust a string chosen by the client.
///
/// See docs/SDK.md, "What crosses the boundary".
public struct GuardSignal {

    /// Opaque base64. Nil when the engine is not configured to seal results.
    public let sealedPayload: String?

    /// The engine's handle for this attempt. Server-resolvable when sealing is
    /// off.
    public let requestId: String?

    /// The engine's own confidence, 0 to 1.
    public let confidence: Double?

    public let source: GuardSource

    public init(
        sealedPayload: String?,
        requestId: String?,
        confidence: Double?,
        source: GuardSource
    ) {
        self.sealedPayload = sealedPayload
        self.requestId = requestId
        self.confidence = confidence
        self.source = source
    }

    /// The answer when Guard is switched off. Not an error; see docs/SDK.md.
    public static func disabled() -> GuardSignal {
        GuardSignal(sealedPayload: nil, requestId: nil, confidence: nil, source: .disabled)
    }

    /// The answer when no engine is registered.
    public static func none() -> GuardSignal {
        GuardSignal(sealedPayload: nil, requestId: nil, confidence: nil, source: .none)
    }

    /// Whether this attempt produced something the server can resolve.
    public var identified: Bool { sealedPayload != nil || requestId != nil }
}

extension GuardSignal: CustomStringConvertible {
    /// Never includes `sealedPayload` or `requestId`.
    ///
    /// A description is what ends up in a log line somebody pastes into a
    /// support ticket, and the sealed payload is a bearer token for "this
    /// device is real" until the server pins it against replay.
    public var description: String {
        let sealed = sealedPayload != nil ? "present" : "absent"
        let score = confidence.map { "\($0)" } ?? "none"
        return "GuardSignal(source=\(source), sealed=\(sealed), confidence=\(score))"
    }
}

/// What an engine needs to run, assembled from the bootstrap response.
///
/// Field names describe the role, never the engine: `publicKey` rather than any
/// vendor's term for it. A wire contract and a value type both outlive the
/// decision to use a particular vendor.
public struct GuardConfig: Equatable {

    public let publicKey: String
    public let region: String?

    /// Absolute URL the engine should talk to instead of its vendor's default.
    ///
    /// Non-nil is the configuration that keeps the vendor's hostname out of a
    /// user's network traffic, which is the cheapest thing about this SDK to
    /// verify and the cheapest to get wrong.
    public let endpoint: String?

    public let endpointFallbacks: [String]
    public let sealedResults: Bool
    public let extendedResult: Bool
    public let locationDataEnabled: Bool
    public let identifyTimeoutMs: Int64

    /// Reported to the engine as integration metadata.
    public let sdkVersion: String

    public init(
        publicKey: String,
        region: String?,
        endpoint: String?,
        endpointFallbacks: [String],
        sealedResults: Bool,
        extendedResult: Bool,
        locationDataEnabled: Bool,
        identifyTimeoutMs: Int64,
        sdkVersion: String
    ) {
        self.publicKey = publicKey
        self.region = region
        self.endpoint = endpoint
        self.endpointFallbacks = endpointFallbacks
        self.sealedResults = sealedResults
        self.extendedResult = extendedResult
        self.locationDataEnabled = locationDataEnabled
        self.identifyTimeoutMs = identifyTimeoutMs
        self.sdkVersion = sdkVersion
    }
}
