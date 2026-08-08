import Foundation

#if canImport(ObjectiveC)
import ObjectiveC

/// How an adapter target offers its engine to the SDK.
///
/// Objective-C visible so that `SignalEngineFactory` can find a conformance by
/// name at runtime without `HertusCore` referring to it at compile time. The
/// method returns `AnyObject` because `SignalEngine` is a Swift protocol and
/// cannot cross the Objective-C boundary as a type; the factory casts it back.
///
/// Apple platforms only. There is no Objective-C runtime elsewhere, and the
/// identification engine ships as an Apple binary, so a host without one was
/// never going to identify anything.
@objc public protocol SignalEngineProviding {
    @objc func makeSignalEngine() -> AnyObject
}
#endif

/// Finds an engine at runtime.
///
/// Resolution runs in two steps, and the order matters:
///
/// 1. Anything explicitly registered, which is how a test supplies a fake and
///    how a host app could supply an engine of its own.
/// 2. Discovery by name through the Objective-C runtime.
///
/// Step 2 is the direct analogue of the `Class.forName` the Android SDK uses,
/// and it exists for the same reason: `HertusCore` names no engine and has no
/// dependency on any adapter, so a build without one carries no trace of it and
/// adding one is a dependency line rather than a code change. Crucially it also
/// means a host app calls `Hertus.initialize` and nothing else. Which engine
/// exists, and whether it should run, is the SDK's business.
///
/// It inherits the same hazard as the Android version: a linker that dead-strips
/// a class nothing references will remove the adapter, and Guard becomes a no-op
/// indistinguishable from a correctly disabled Guard. On Apple platforms the fix
/// is the `-ObjC` linker flag, which is the counterpart of the keep rule that
/// ships inside the Android AAR. `HertusGuardS1.enable()` remains available as a
/// belt-and-braces alternative for a host app that cannot set the flag.
public final class SignalEngineFactory {

    /// One registry for the process, matching the SDK being a singleton.
    public static let shared = SignalEngineFactory()

    /// Adapter classes this build knows how to look for, keyed by the `provider`
    /// discriminator from the bootstrap response.
    ///
    /// A map rather than an if, so that shipping a second engine is an entry
    /// here plus a target, and so an unrecognised provider has one obvious
    /// answer rather than a fallthrough somebody has to reason about. The values
    /// are Objective-C class names and, like the keys, they name nobody.
    static let discoverable: [String: String] = [
        "s1": "HertusSignalEngineProviderS1",
    ]

    private let lock = NSLock()
    private var factories: [String: () -> SignalEngine] = [:]

    public init() {}

    /// Registers an engine under the `provider` discriminator the bootstrap
    /// response uses, ahead of anything discovery would find.
    ///
    /// Registering the same provider twice replaces the first, so a host app
    /// doing it more than once is harmless rather than an error a measurement
    /// library has any business raising.
    public func register(provider: String, factory: @escaping () -> SignalEngine) {
        lock.lock()
        defer { lock.unlock() }
        factories[provider] = factory
    }

    /// Forgets every registration. For tests, which must not leak an engine
    /// into each other.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        factories.removeAll()
    }

    /// Whether `provider` names an engine this build could produce, from either
    /// step.
    public func canResolve(_ provider: String?) -> Bool {
        guard let provider else { return false }

        lock.lock()
        let registered = factories[provider] != nil
        lock.unlock()

        return registered || discover(provider) != nil
    }

    /// The engine for `provider`, or a `NoopSignalEngine`.
    ///
    /// Never throws and never returns nil. An unknown provider, a missing
    /// adapter and a stripped class all mean the same thing upstream, which is
    /// that Guard will produce nothing and the SDK carries on without it.
    public func resolve(_ provider: String?) -> SignalEngine {
        guard let provider else { return NoopSignalEngine() }

        lock.lock()
        let registered = factories[provider]
        lock.unlock()

        if let registered { return registered() }
        return discover(provider) ?? NoopSignalEngine()
    }

    /// Looks for the adapter through the Objective-C runtime.
    ///
    /// Returns nil off Apple platforms, where there is no such runtime. That is
    /// not a degraded path: the identification engine ships as an Apple binary,
    /// so a host without it was never going to identify anything.
    private func discover(_ provider: String) -> SignalEngine? {
        #if canImport(ObjectiveC)
        guard
            let className = SignalEngineFactory.discoverable[provider],
            let type = NSClassFromString(className) as? NSObject.Type,
            let providing = type.init() as? SignalEngineProviding
        else { return nil }

        return providing.makeSignalEngine() as? SignalEngine
        #else
        _ = provider
        return nil
        #endif
    }
}
