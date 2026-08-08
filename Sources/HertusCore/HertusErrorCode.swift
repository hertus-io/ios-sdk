import Foundation

/// Everything that can go wrong, as a closed set.
///
/// kebab-case wire values, matching `protect.FilterKey` on the server and the
/// Android SDK exactly, so one vocabulary spans the platform. These are
/// load-bearing strings: a developer reads one in a console and searches for
/// it, a wrapper SDK switches on it, and a support conversation quotes it.
/// Renaming one is a breaking change to every integration, not an edit.
///
/// Generated from `sdk/contract/errors.yaml`.
public enum HertusErrorCode: String, CaseIterable {

    /// The config could not be used at all: a malformed token, usually.
    case configurationInvalid = "configuration-invalid"

    /// A call arrived before `Hertus.initialize`.
    case notInitialized = "not-initialized"

    /// No usable network. Expected, frequent, and not a fault.
    case networkUnavailable = "network-unavailable"

    case timeout

    /// The server refused the credential. Terminal: the SDK stops asking.
    case serverRejected = "server-rejected"

    /// The server is having a bad time. Retried with backoff.
    case serverUnavailable = "server-unavailable"

    /// Guard is switched off, by the server or by config.
    ///
    /// Present for completeness. It is deliberately not reported through an
    /// error path, because a configuration state is not a failure.
    case guardDisabled = "guard-disabled"

    /// No identification engine is present in this build.
    case guardUnavailable = "guard-unavailable"

    /// The engine's credentials are wrong, expired, or not entitled.
    case guardCredentials = "guard-credentials"

    /// The engine's request allowance is spent.
    case guardQuota = "guard-quota"

    case guardTimeout = "guard-timeout"

    case guardNetwork = "guard-network"

    /// Identification answered with something unparseable.
    case guardResponseInvalid = "guard-response-invalid"

    /// This device, app or configuration is not one the engine will serve.
    case guardUnsupported = "guard-unsupported"

    /// A wrapper called a bridge method this SDK does not know, which is what a
    /// newer wrapper against an older native SDK produces. A structured error
    /// rather than the platform's own missing-method failure, because the
    /// latter reads to a customer as a broken SDK.
    case unsupportedOperation = "unsupported-operation"

    /// A bug in this SDK.
    case internalError = "internal"

    /// What the SDK says about this code.
    ///
    /// Fixed here, per code, and never derived from an underlying engine's own
    /// error text, because that text names the vendor.
    public var message: String {
        switch self {
        case .configurationInvalid:
            return "The Hertus configuration is not usable. Check the app token."
        case .notInitialized:
            return "Hertus is not initialized. Call Hertus.initialize before anything you want measured."
        case .networkUnavailable:
            return "No network connection is available."
        case .timeout:
            return "The request timed out."
        case .serverRejected:
            return "The server rejected this app token. Check it against the dashboard, and that the app is not archived."
        case .serverUnavailable:
            return "The Hertus server is unavailable."
        case .guardDisabled:
            return "Guard is disabled for this app."
        case .guardUnavailable:
            return "No Guard engine is available in this build."
        case .guardCredentials:
            return "Guard could not authenticate."
        case .guardQuota:
            return "Guard has exhausted its request quota."
        case .guardTimeout:
            return "Guard timed out."
        case .guardNetwork:
            return "Guard could not reach the network."
        case .guardResponseInvalid:
            return "Guard returned a response that could not be read."
        case .guardUnsupported:
            return "Guard is not supported in this configuration."
        case .unsupportedOperation:
            return "This operation is not available in the installed Hertus SDK."
        case .internalError:
            return "An internal Hertus error occurred."
        }
    }

    /// What the server is told, and what a developer greps for.
    public var wireValue: String { rawValue }

    /// Resolves a wire value, or nil. Wrapper SDKs parse rather than guess.
    public static func fromWireValue(_ value: String) -> HertusErrorCode? {
        HertusErrorCode(rawValue: value)
    }
}
