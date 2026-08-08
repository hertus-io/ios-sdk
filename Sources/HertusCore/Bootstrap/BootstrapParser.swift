import Foundation

/// Turns a bootstrap response into a `BootstrapConfig`.
///
/// Two rules, both of which exist because this code runs inside apps that are
/// already in an app store and cannot be updated when the server changes:
///
/// 1. **Unknown fields are ignored, never rejected.** A server newer than a
///    client will send things this build has never heard of. Failing on them
///    would mean any additive change to the contract breaks every old client at
///    once, which is the failure mode that makes teams afraid to touch a
///    contract.
/// 2. **Every optional field has a default that is safe on its own.** A
///    half-written response produces a working, quieter SDK rather than a
///    failure on a background queue.
///
/// Uses `JSONSerialization` because it is in the platform. A parser is not worth
/// a dependency in somebody else's dependency tree.
public enum BootstrapParser {

    static let minIdentifyTimeoutMs: Int64 = 500
    static let maxIdentifyTimeoutMs: Int64 = 60_000

    /// Returns nil if `raw` is not a JSON object at all. The caller treats that
    /// as a server fault, because it is one.
    public static func parse(_ raw: String) -> BootstrapConfig? {
        guard
            let data = raw.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let guardSettings = (root["guard"] as? [String: Any]).map(parseGuard) ?? GuardSettings.off()
        let ingest = root["ingest"] as? [String: Any]

        return BootstrapConfig(
            configVersion: string(root, "configVersion"),
            ttlSeconds: clamp(
                integer(root, "ttlSeconds") ?? BootstrapConfig.defaultTtlSeconds,
                BootstrapConfig.minTtlSeconds,
                BootstrapConfig.maxTtlSeconds
            ),
            guardSettings: guardSettings,
            ingestEnabled: boolean(ingest, "enabled") ?? false,
            ingestEndpoint: string(ingest, "endpoint")
        )
    }

    private static func parseGuard(_ json: [String: Any]) -> GuardSettings {
        GuardSettings(
            // Defaults false: an SDK that starts identifying devices because a
            // field was missing is doing something nobody asked it to do.
            enabled: boolean(json, "enabled") ?? false,
            provider: string(json, "provider"),
            publicKey: string(json, "publicKey"),
            region: string(json, "region"),
            endpoint: string(json, "endpoint"),
            endpointFallbacks: strings(json, "endpointFallbacks"),
            sealedResults: boolean(json, "sealedResults") ?? false,
            extendedResult: boolean(json, "extendedResult") ?? false,
            locationDataEnabled: boolean(json, "locationDataEnabled") ?? false,
            // A zero or negative timeout means "never finish"; a ten-minute one
            // means a wedged launch. Neither is a thing to honour faithfully.
            identifyTimeoutMs: clamp(
                integer(json, "identifyTimeoutMs") ?? GuardSettings.defaultIdentifyTimeoutMs,
                minIdentifyTimeoutMs,
                maxIdentifyTimeoutMs
            )
        )
    }

    // MARK: reading

    /// Blank and JSON null both become nil.
    ///
    /// A blank string that reached the engine as a credential would fail on
    /// every launch with an error pointing at the subscription rather than at
    /// the empty field that caused it.
    private static func string(_ json: [String: Any]?, _ key: String) -> String? {
        guard let value = json?[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private static func integer(_ json: [String: Any]?, _ key: String) -> Int64? {
        guard let value = json?[key], !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func boolean(_ json: [String: Any]?, _ key: String) -> Bool? {
        guard let value = json?[key], !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let flag = value as? Bool { return flag }
        return nil
    }

    private static func strings(_ json: [String: Any]?, _ key: String) -> [String] {
        guard let raw = json?[key] as? [Any] else { return [] }
        return raw.compactMap { element in
            guard let text = element as? String else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }

    private static func clamp(_ value: Int64, _ lower: Int64, _ upper: Int64) -> Int64 {
        min(max(value, lower), upper)
    }
}
