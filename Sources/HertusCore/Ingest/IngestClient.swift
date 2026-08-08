import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What one batch upload produced.
///
/// The cases mirror bootstrap's deliberately. Two endpoints disagreeing about
/// what 401 means is the kind of difference that is found by a customer.
public enum IngestOutcome: Equatable {

    /// The server has the batch. Drop it.
    case accepted

    /// The batch was malformed and will be malformed again.
    ///
    /// Dropped rather than retried: retrying a payload the server has already
    /// refused to parse is how one bad event blocks a queue forever.
    case refused(status: Int)

    /// The server refused this app. Terminal for the process.
    case rejected(status: Int)

    /// The batch was too large. Halve it and try again.
    case tooLarge

    /// Our fault or the network's. Keep the queue and try later.
    case unavailable(reason: String, retryAfterSeconds: Int64? = nil)
}

/// Evidence that this device is what it claims to be, as forwarded to ingest.
///
/// One per batch rather than one per event: identification happens once per
/// launch, and copying it onto every event would multiply a bearer token by the
/// event count.
public struct GuardEvidence: Equatable {

    public let sealedPayload: String?
    public let requestId: String?
    public let confidence: Double?

    public init(sealedPayload: String?, requestId: String?, confidence: Double?) {
        self.sealedPayload = sealedPayload
        self.requestId = requestId
        self.confidence = confidence
    }

    /// Nil when Guard produced nothing worth sending, so an absent block and an
    /// empty one are not two ways of saying the same thing.
    public init?(signal: GuardSignal?) {
        guard let signal, signal.identified else { return nil }
        self.init(
            sealedPayload: signal.sealedPayload,
            requestId: signal.requestId,
            confidence: signal.confidence
        )
    }
}

/// Sends one batch of events.
///
/// Single-shot, like `BootstrapClient`: it performs one request and reports what
/// happened. Batching and retrying are `IngestPipeline`'s decisions, because
/// both depend on the queue, which this has no business knowing about.
public protocol IngestUploader: AnyObject {
    func send(
        payloads: [String],
        evidence: GuardEvidence?,
        completion: @escaping (IngestOutcome) -> Void
    )
}

/// The real uploader.
public final class IngestClient: IngestUploader {

    /// Appended to the ingest endpoint from the bootstrap response, or to the
    /// ordinary server URL when the server named none.
    public static let path = "/api/v1/sdk/events"

    /// Longer than bootstrap's, because this does not run during a launch and a
    /// batch is larger than a configuration.
    public static let timeoutSeconds: TimeInterval = 30

    private let baseUrl: String
    private let appToken: String
    private let environment: HertusEnvironment
    private let device: DeviceInfo
    private let log: Logger
    private let session: URLSession
    private let now: () -> Int64

    public init(
        baseUrl: String,
        appToken: String,
        environment: HertusEnvironment,
        device: DeviceInfo,
        log: Logger,
        session: URLSession? = nil,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.baseUrl = baseUrl
        self.appToken = appToken
        self.environment = environment
        self.device = device
        self.log = log
        self.now = now

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = IngestClient.timeoutSeconds
            configuration.timeoutIntervalForResource = IngestClient.timeoutSeconds
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(
        payloads: [String],
        evidence: GuardEvidence?,
        completion: @escaping (IngestOutcome) -> Void
    ) {
        guard !payloads.isEmpty else {
            completion(.accepted)
            return
        }

        guard
            let url = URL(string: baseUrl + IngestClient.path),
            let body = requestBody(payloads: payloads, evidence: evidence)
        else {
            completion(.unavailable(reason: "ingest URL is not usable"))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = IngestClient.timeoutSeconds
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")

        session.dataTask(with: request) { [log] _, response, error in
            if let error {
                log.v("ingest request failed: \(error.localizedDescription)")
                completion(.unavailable(reason: (error as NSError).domain))
                return
            }

            guard let http = response as? HTTPURLResponse else {
                completion(.unavailable(reason: "no HTTP response"))
                return
            }

            completion(
                IngestClient.outcome(
                    status: http.statusCode,
                    retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                )
            )
        }.resume()
    }

    /// Takes the one header it needs rather than the whole response, so the
    /// mapping can be stated as a table in a test without a URL loading system.
    static func outcome(status: Int, retryAfter: String?) -> IngestOutcome {
        switch status {
        case 200, 202:
            return .accepted
        case 400:
            return .refused(status: status)
        case 401, 403:
            return .rejected(status: status)
        case 413:
            return .tooLarge
        case 429:
            return .unavailable(reason: "rate limited", retryAfterSeconds: retryAfter.flatMap { Int64($0) })
        default:
            return .unavailable(reason: "server returned \(status)")
        }
    }

    /// The envelopes are already JSON, so they are spliced in as text rather
    /// than parsed and re-encoded. Round-tripping every event through
    /// `JSONSerialization` on the way out would cost the one thing a batch of
    /// fifty is trying to save.
    private func requestBody(payloads: [String], evidence: GuardEvidence?) -> Data? {
        var envelope: [String: Any] = [
            "sdkVersion": device.sdkVersion,
            "platform": SdkInfo.platform,
            "environment": environment.wireValue,
            "sentAtMillis": now(),
            "device": [
                "osVersion": device.osVersion,
                "packageName": device.bundleId,
                "appVersion": device.appVersion,
                "deviceModel": device.deviceModel,
                "locale": device.locale,
            ],
        ]

        if let evidence {
            var block: [String: Any] = [:]
            if let sealed = evidence.sealedPayload { block["sealedPayload"] = sealed }
            if let requestId = evidence.requestId { block["requestId"] = requestId }
            if let confidence = evidence.confidence { block["confidence"] = confidence }
            if !block.isEmpty { envelope["guard"] = block }
        }

        guard
            var data = try? JSONSerialization.data(withJSONObject: envelope),
            var text = String(data: data, encoding: .utf8),
            text.hasSuffix("}")
        else { return nil }

        text.removeLast()
        text += ",\"events\":[" + payloads.joined(separator: ",") + "]}"
        data = Data(text.utf8)
        return data
    }
}
