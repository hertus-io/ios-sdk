#if canImport(FingerprintPro)

import Foundation
import HertusCore
import FingerprintPro

/// The engine's error taxonomy, mapped onto ours.
///
/// Exhaustive over what the vendor documents, plus a default, so a new case in
/// a future version degrades to `internal` rather than failing to compile a
/// customer's app.
///
/// The mapping mirrors the Android adapter deliberately. The two SDKs reporting
/// different codes for the same underlying condition would be found by a
/// customer comparing dashboards, not by a build.
///
/// **The vendor's error text is never copied into a `HertusError`.** Our
/// messages are our own fixed English per code; their wording travels only as
/// the verbose diagnostic, which does not exist in production builds.
enum S1ErrorMapping {

    static func code(for error: FPJSError) -> HertusErrorCode {
        switch error {
        case .clientTimeout:
            return .guardTimeout

        case .networkError:
            return .guardNetwork

        // Parsed but unusable. The request reached the engine and came back
        // wrong, which is a different operator problem from not reaching it.
        case .jsonParsingError, .invalidResponseType:
            return .guardResponseInvalid

        // A malformed endpoint is a configuration this device cannot serve, and
        // it is ours or the server's mistake rather than the network's.
        case .invalidURL, .invalidURLParams:
            return .guardUnsupported

        case .apiError(let apiError):
            return code(forApi: apiError)

        case .unknownError:
            return .internalError

        @unknown default:
            return .internalError
        }
    }

    /// The engine's API errors, keyed by the code it puts on the wire.
    ///
    /// Eight unrelated causes collapse into `guardCredentials` because the
    /// operator response to all of them is the same: somebody looks at the
    /// subscription. Quota is kept apart from it, and both are kept apart from
    /// a network failure, because those three lead to different people.
    private static func code(forApi apiError: APIError) -> HertusErrorCode {
        switch apiError.error?.code?.rawValue {
        case "TokenRequired",
             "TokenNotFound",
             "TokenExpired",
             "SubscriptionNotActive",
             "WrongRegion",
             "InvalidProxyIntegrationSecret",
             "InvalidProxyIntegrationHeaders",
             "HeaderRestricted":
            return .guardCredentials

        case "TooManyRequests", "RequestThrottled":
            return .guardQuota

        case "InstallationMethodRestricted",
             "HostnameRestricted",
             "NotAvailableForCrawlBots",
             "NotAvailableWithoutUA":
            return .guardUnsupported

        case "RequestCannotBeParsed", "Failed":
            return .guardResponseInvalid

        default:
            return .internalError
        }
    }
}

#endif
