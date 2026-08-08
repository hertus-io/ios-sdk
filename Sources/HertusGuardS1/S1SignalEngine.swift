#if canImport(FingerprintPro)

import Foundation
import HertusCore
import FingerprintPro

/// The adapter onto the identification engine.
///
/// **This file, and this file alone, imports the vendor.** Everything above it
/// is written as though device identification were a solved local problem. That
/// is what makes swapping the engine, running two, or shipping none of them a
/// change to one target rather than a change everywhere, and it is why no
/// shipped symbol outside this target names the vendor. See docs/SDK.md,
/// "Naming discipline".
///
/// Compiled only when the engine is present. A build without it produces an
/// empty module, `HertusGuardS1.enable()` answers false, and the SDK runs with
/// Guard off, which is a supported configuration rather than a degraded one.
final class S1SignalEngine: SignalEngine {

    private var client: FingerprintClientProviding?

    /// What the engine is told it is embedded in. Our own name, not the
    /// vendor's, and not the host app's.
    private static let integrationName = "hertus-ios"

    init() {}

    func start(config: GuardConfig) {
        // A custom domain replaces the region entirely, which is the
        // configuration that keeps the vendor's hostname out of a user's
        // network traffic.
        let region: Region
        if let endpoint = config.endpoint {
            region = .custom(domain: endpoint, fallback: config.endpointFallbacks)
        } else {
            switch config.region {
            case "eu": region = .eu
            case "ap": region = .ap
            default: region = .global
            }
        }

        client = FingerprintProFactory.getInstance(
            Configuration(
                apiKey: config.publicKey,
                region: region,
                integrationInfo: [(S1SignalEngine.integrationName, config.sdkVersion)],
                extendedResponseFormat: config.extendedResult,
                allowUseOfLocationData: config.locationDataEnabled
            )
        )
    }

    func identify(timeoutMs: Int64, handler: @escaping EngineResultHandler) {
        guard let client else {
            handler(nil, HertusError(code: .guardUnavailable), "identify before start")
            return
        }

        // The vendor counts in seconds; the rest of the platform counts in
        // milliseconds, because that is what the bootstrap response carries.
        let timeout = Double(timeoutMs) / 1000

        client.getVisitorIdResponse(nil, timeout: timeout) { result in
            switch result {
            case .success(let response):
                handler(
                    GuardSignal(
                        // The sealed blob is the only identifying thing that
                        // crosses this boundary. The visitor id the engine also
                        // produces is deliberately never read: it can be forged
                        // by a modified client, and the sealed payload cannot.
                        sealedPayload: response.sealedResult,
                        requestId: response.requestId,
                        confidence: Double(response.confidence),
                        source: .engine
                    ),
                    nil,
                    nil
                )

            case .failure(let error):
                // The vendor's own wording travels as the diagnostic, which is
                // logged at verbose and nowhere else. It is never copied into
                // the message, because the message is ours and it does not name
                // anybody.
                handler(nil, HertusError(code: S1ErrorMapping.code(for: error)), "\(error)")
            }
        }
    }

    func shutdown() {
        client = nil
    }
}

#endif
