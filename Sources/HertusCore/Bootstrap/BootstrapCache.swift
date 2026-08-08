import Foundation

#if canImport(CryptoKit)
import CryptoKit
#endif

/// Remembers the last good configuration, so a cold start does no network work.
///
/// The effect worth stating: with a warm cache, Guard begins within
/// milliseconds of `initialize` and the SDK makes one bootstrap request per TTL
/// window rather than one per launch. An app opened ten times an hour asks once
/// every six.
///
/// **Not encrypted, deliberately.** The payload holds nothing secret (see
/// docs/SDK.md, "Security properties"), and reaching for the Keychain would add
/// a failure mode on locked devices and slower reads in order to protect a value
/// that also ships inside the app bundle.
public final class BootstrapCache: ConfigurationStore {

    private let defaults: UserDefaults
    private let prefix: String
    private let now: () -> Int64

    /// Keyed by token and environment, so both ways a configuration can become
    /// wrong invalidate it without an explicit mechanism:
    ///
    /// - Rotating the SDK key changes the token, so the old entry is simply
    ///   never read again.
    /// - Switching a build from sandbox to production cannot serve the other
    ///   environment's answer out of a cache that outlived the change.
    ///
    /// Hashed rather than stored plainly, because a token in a key is a token in
    /// every bug report that includes a defaults dump.
    public init(
        appToken: String,
        environment: HertusEnvironment,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.defaults = defaults
        self.prefix = "hertus_bootstrap_" + BootstrapCache.cacheKey(appToken, environment) + "_"
        self.now = now
    }

    public func read() -> CachedConfiguration? {
        guard
            let payload = defaults.string(forKey: prefix + Key.payload),
            !payload.isEmpty
        else { return nil }

        guard let fetchedAt = integer(Key.fetchedAt), fetchedAt > 0 else { return nil }

        let ageSeconds = (now() - fetchedAt) / 1000

        // A clock that moved backwards (a timezone change, an NTP correction, a
        // user setting the date) would otherwise make an entry look arbitrarily
        // fresh. Treated as unusable rather than trusted.
        guard ageSeconds >= 0 else { return nil }

        return CachedConfiguration(
            payload: payload,
            configVersion: defaults.string(forKey: prefix + Key.configVersion),
            ageSeconds: ageSeconds,
            ttlSeconds: integer(Key.ttl) ?? BootstrapConfig.defaultTtlSeconds
        )
    }

    public func write(payload: String, configVersion: String?, ttlSeconds: Int64) {
        defaults.set(payload, forKey: prefix + Key.payload)
        defaults.set(configVersion, forKey: prefix + Key.configVersion)
        defaults.set(Int(now()), forKey: prefix + Key.fetchedAt)
        defaults.set(Int(ttlSeconds), forKey: prefix + Key.ttl)
    }

    /// The 304 path: the server has confirmed what we hold is current, so the
    /// clock restarts and the payload is not reparsed.
    public func touch() {
        defaults.set(Int(now()), forKey: prefix + Key.fetchedAt)
    }

    /// Reads a whole number, distinguishing absent from zero.
    ///
    /// `object(forKey:) as? Int64` is the obvious spelling and it is wrong:
    /// what comes back is a bridged `NSNumber` or a platform `Int` depending on
    /// the Foundation underneath, so the cast fails and every stored number
    /// silently becomes its default.
    private func integer(_ key: String) -> Int64? {
        guard defaults.object(forKey: prefix + key) != nil else { return nil }
        return Int64(defaults.integer(forKey: prefix + key))
    }

    public func clear() {
        for key in [Key.payload, Key.configVersion, Key.fetchedAt, Key.ttl] {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    private enum Key {
        static let payload = "payload"
        static let configVersion = "config_version"
        static let fetchedAt = "fetched_at"
        static let ttl = "ttl_seconds"
    }

    /// First 16 hex characters of a digest over `token|environment`.
    ///
    /// Named `cacheKey` and not the other obvious word for a short hash. That
    /// word appears in the identification vendor's name, and the way anyone
    /// checks a built artefact is clean is by searching it for that word. A
    /// false positive there costs somebody an afternoon, or reads as evidence of
    /// the opposite.
    static func cacheKey(_ appToken: String, _ environment: HertusEnvironment) -> String {
        let input = "\(appToken)|\(environment.wireValue)"

        #if canImport(CryptoKit)
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        #else
        // No CryptoKit off Apple platforms. This path exists so the package
        // builds and tests on any host; what it protects is a defaults key, not
        // a secret, so a non-cryptographic digest is adequate for it.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Data(input.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016lx", hash)
        #endif
    }
}
