import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one request the SDK makes before it can do anything else.
///
/// `URLSession`, and nothing else. An SDK's dependencies become its host app's
/// dependencies, and every one is a potential version conflict in somebody
/// else's build for the rest of the SDK's life. One POST and one JSON body does
/// not justify that.
///
/// Single-shot: it performs one request and reports what happened. Retrying is
/// `BootstrapSequence`'s decision, because whether to retry depends on whether
/// there is a usable cache, which this class has no business knowing.
public final class BootstrapClient: ConfigurationFetcher {

    /// Appended to the configured server URL, which is therefore a bare origin
    /// and not a base path.
    ///
    /// The version lives in the server's own prefix (`/api/v1`) rather than in a
    /// path segment of ours, so this endpoint is versioned with the rest of the
    /// API instead of separately. Changing it is a breaking change for every
    /// build already in an app store, which is why it is a constant here and not
    /// a configurable.
    public static let path = "/api/v1/sdk/bootstrap"

    /// Deliberately short. This runs during app startup, and an SDK that can
    /// hold a launch for thirty seconds on a bad network is worse than one that
    /// gives up and uses its cache.
    public static let timeoutSeconds: TimeInterval = 10

    static let statusTooManyRequests = 429

    private let baseUrl: String
    private let appToken: String
    private let environment: HertusEnvironment
    private let device: DeviceInfo
    private let log: Logger
    private let session: URLSession

    public init(
        baseUrl: String,
        appToken: String,
        environment: HertusEnvironment,
        device: DeviceInfo,
        log: Logger,
        session: URLSession? = nil
    ) {
        self.baseUrl = baseUrl
        self.appToken = appToken
        self.environment = environment
        self.device = device
        self.log = log

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = BootstrapClient.timeoutSeconds
            configuration.timeoutIntervalForResource = BootstrapClient.timeoutSeconds
            // The response is a few hundred bytes and is cached by us, with our
            // own TTL. A second cache underneath that one only adds a way for
            // the two to disagree.
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func fetch(configVersion: String?, completion: @escaping (BootstrapOutcome) -> Void) {
        guard
            let url = URL(string: baseUrl + BootstrapClient.path),
            let body = try? JSONSerialization.data(withJSONObject: requestBody(configVersion))
        else {
            completion(.unavailable(reason: "server URL is not usable"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = BootstrapClient.timeoutSeconds
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: request) { [log] data, response, error in
            if let error {
                // Timeouts, DNS failures and TLS failures all mean "try later"
                // here, and the distinction goes to the log rather than into
                // control flow.
                log.v("bootstrap request failed: \(error.localizedDescription)")
                completion(.unavailable(reason: (error as NSError).domain))
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.unavailable(reason: "no HTTP response"))
                return
            }

            completion(BootstrapClient.outcome(status: http.statusCode, headers: http, data: data))
        }.resume()
    }

    static func outcome(status: Int, headers: HTTPURLResponse, data: Data?) -> BootstrapOutcome {
        switch status {
        case 200:
            guard
                let data,
                let payload = String(data: data, encoding: .utf8),
                !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return .unavailable(reason: "server returned an empty body")
            }
            return .fetched(payload: payload)

        case 304:
            return .notModified

        case 401, 403:
            return .rejected(status: status)

        case statusTooManyRequests:
            let retryAfter = (headers.value(forHTTPHeaderField: "Retry-After")).flatMap { Int64($0) }
            return .unavailable(reason: "rate limited", retryAfterSeconds: retryAfter)

        default:
            return .unavailable(reason: "server returned \(status)")
        }
    }

    /// See docs/SDK.md for what each field is for. No device identifiers.
    private func requestBody(_ configVersion: String?) -> [String: Any] {
        var body: [String: Any] = [
            "sdkVersion": device.sdkVersion,
            "platform": SdkInfo.platform,
            "environment": environment.wireValue,
            "osVersion": device.osVersion,
            "packageName": device.bundleId,
            "appVersion": device.appVersion,
            "deviceModel": device.deviceModel,
            "locale": device.locale,
        ]
        if let configVersion {
            body["configVersion"] = configVersion
        }
        return body
    }
}
