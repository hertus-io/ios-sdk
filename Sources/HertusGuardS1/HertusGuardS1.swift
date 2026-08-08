import Foundation
import HertusCore

/// Switches Guard on for this build.
///
/// ```swift
/// HertusGuardS1.enable()
/// Hertus.initialize(config)
/// ```
///
/// One line, and it has to be written: Swift has no portable equivalent of the
/// reflection the Android SDK uses to find its adapter, so registration is
/// explicit here. That is a trade rather than a loss. On Android the reflective
/// lookup is invisible to R8, which strips the adapter from minified builds and
/// turns Guard into a no-op that looks exactly like a correctly disabled Guard;
/// a keep rule has to ship inside the AAR to prevent it. Nothing can strip a
/// registration that was executed.
///
/// Calling it more than once is harmless. Not calling it at all is a supported
/// configuration: the SDK runs with Guard off rather than failing.
public enum HertusGuardS1 {

    /// The `provider` discriminator the bootstrap response uses for this
    /// engine. Deliberately opaque, and deliberately not the vendor's name.
    public static let providerKey = "s1"

    /// Registers the engine, and reports whether there was one to register.
    ///
    /// Returns false when this build was compiled without the identification
    /// engine available, which is worth surfacing rather than hiding: an
    /// integrator who called `enable()` and got Guard anyway has a dependency
    /// problem, and silence would send them to the dashboard instead.
    @discardableResult
    public static func enable(into factory: SignalEngineFactory = .shared) -> Bool {
        #if canImport(FingerprintPro)
        factory.register(provider: providerKey) { S1SignalEngine() }
        return true
        #else
        return false
        #endif
    }

    /// Whether this build carries an identification engine at all.
    public static var isAvailable: Bool {
        #if canImport(FingerprintPro)
        return true
        #else
        return false
        #endif
    }
}
