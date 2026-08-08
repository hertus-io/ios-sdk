import Foundation
import HertusCore

/// The identification engine, as a host app sees it.
///
/// **There is normally nothing to call.** Adding this library to a target is the
/// whole integration: `SignalEngineFactory` finds the adapter through the
/// Objective-C runtime, and `Hertus.initialize` decides whether it actually runs
/// from `guardEnabled`, the environment and the server's answer. That is the
/// same arrangement as the Android SDK, where `Class.forName` does the finding
/// and the host app calls `initialize` and nothing else.
///
/// ```swift
/// Hertus.initialize(config)
/// ```
///
/// `enable()` exists for the one case where that fails. Runtime lookup is
/// invisible to the linker, so a build with aggressive dead stripping can remove
/// the adapter and leave Guard a no-op indistinguishable from a correctly
/// disabled Guard. On Apple platforms the fix is the `-ObjC` linker flag, which
/// is the counterpart of the keep rule that ships inside the Android AAR. A host
/// app that cannot set it can register explicitly instead.
public enum HertusGuardS1 {

    /// The `provider` discriminator the bootstrap response uses for this
    /// engine. Deliberately opaque, and deliberately not the vendor's name.
    public static let providerKey = "s1"

    /// Registers the engine explicitly, ahead of runtime discovery, and reports
    /// whether there was one to register.
    ///
    /// Not normally needed. Call it before `Hertus.initialize` only when the
    /// linker strips the adapter and `-ObjC` is not an option.
    ///
    /// Returns false when this build was compiled without the identification
    /// engine available, which is worth surfacing rather than hiding: an
    /// integrator who called this and still got no Guard has a dependency
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
