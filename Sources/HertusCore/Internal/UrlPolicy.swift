import Foundation

/// Whether a URL handed to the SDK may be used.
///
/// Two callers, and both matter. `HertusConfig.serverUrl` is how a developer
/// points the SDK at a server on their own machine. The Guard endpoint arrives
/// over the network and is handed to a component that will make requests to it,
/// so it is checked like any other untrusted input.
///
/// The rule is one sentence: https anywhere, cleartext only in sandbox and only
/// to an address that cannot be on the public internet.
public enum UrlPolicy {

    /// The URL if it is acceptable, normalised to an origin, otherwise nil.
    ///
    /// An origin rather than whatever was passed, because the SDK appends the
    /// versioned API path itself and a trailing path here would produce
    /// requests to `/api/v1/api/v1/...` that fail in a way nobody enjoys
    /// diagnosing.
    public static func accept(_ raw: String?, environment: HertusEnvironment) -> String? {
        guard let raw else { return nil }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty
        else { return nil }

        switch scheme {
        case "https":
            break
        case "http":
            // Cleartext is a sandbox affordance for local development, never a
            // production one. A production build that accepted it would be one
            // proxy away from posting measurement in the clear.
            guard environment == .sandbox, isLocal(host) else { return nil }
        default:
            return nil
        }

        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Addresses that cannot be reached from the public internet.
    ///
    /// `10.0.2.2` is the Android emulator's route to its host. It is accepted
    /// here too so that one server URL works from both SDKs during
    /// development, which is worth more than the precision of excluding it.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            return true
        }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }

        // RFC1918, plus loopback for anything in 127/8.
        switch (parts[0], parts[1]) {
        case (10, _): return true
        case (127, _): return true
        case (192, 168): return true
        case (172, let second) where (16...31).contains(second): return true
        default: return false
        }
    }
}
