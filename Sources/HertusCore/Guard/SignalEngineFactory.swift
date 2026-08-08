import Foundation

/// Finds an engine, by name, at runtime.
///
/// A registry rather than reflection, which is where this departs from the
/// Android SDK and improves on it. There, `Class.forName` keeps `hertus-core`
/// free of any compile-time reference to the adapter, at the cost of R8 not
/// seeing the class is reachable and stripping it from minified builds, so
/// Guard silently becomes a no-op that looks exactly like a correctly disabled
/// Guard. A keep rule has to ship in the AAR to prevent it.
///
/// Swift has no portable equivalent of `Class.forName`, and the registry gets
/// the same property without the hazard: `HertusCore` names no engine, no
/// linker can strip a registration that was executed, and a build without the
/// adapter is a working SDK with Guard off rather than a link error.
///
/// The cost is that registration is explicit. `HertusGuard.enable()` has to be
/// called before `Hertus.initialize`, which is one line in a host app and is
/// documented where they will look for it.
public final class SignalEngineFactory {

    /// One registry for the process, matching the SDK being a singleton.
    public static let shared = SignalEngineFactory()

    private let lock = NSLock()
    private var factories: [String: () -> SignalEngine] = [:]

    public init() {}

    /// Registers an engine under the `provider` discriminator the bootstrap
    /// response uses.
    ///
    /// Registering the same provider twice replaces the first, so a host app
    /// calling `enable()` more than once is harmless rather than an error a
    /// measurement library would have no business raising.
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

    /// Whether `provider` names an engine this build could construct.
    public func knows(_ provider: String?) -> Bool {
        guard let provider else { return false }
        lock.lock()
        defer { lock.unlock() }
        return factories[provider] != nil
    }

    /// Returns the engine for `provider`, or a `NoopSignalEngine`.
    ///
    /// Never throws and never returns nil. An unknown provider and a missing
    /// registration mean the same thing to everything upstream, which is that
    /// Guard will produce nothing and the SDK carries on without it.
    public func create(_ provider: String?) -> SignalEngine {
        guard let provider else { return NoopSignalEngine() }

        lock.lock()
        let factory = factories[provider]
        lock.unlock()

        return factory?() ?? NoopSignalEngine()
    }
}
