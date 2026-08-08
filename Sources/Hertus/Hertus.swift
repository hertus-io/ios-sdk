@_exported import HertusCore
import Foundation

/// The Hertus SDK.
///
/// ```swift
/// let config = HertusConfig(appToken: Secrets.hertusToken, environment: .production)
/// Hertus.initialize(config)
/// ```
///
/// Call `initialize` once, as early in startup as possible, before anything you
/// want measured. It returns immediately; the work it starts happens off the
/// calling thread.
///
/// **There is nothing else to call.** Guard finds its engine at runtime and
/// decides whether to run it from `guardEnabled`, the environment and the
/// server's answer. Adding the `HertusGuardS1` library to a target is the whole
/// of that integration.
///
/// A namespace rather than an instantiable object, because there is one device
/// and one app, and an SDK that could be created twice would let two instances
/// race over the same cache and the same identification quota. The logic lives
/// in `HertusRuntime` behind it, so that being a singleton is a property of the
/// entry point rather than of the implementation.
///
/// **Nothing here throws.** Every method is safe to call at any time, in any
/// order, on any thread. A misconfigured SDK reports through
/// `HertusConfig.onError` and logs under the `io.hertus.sdk` subsystem; it does
/// not take the host app down with it.
///
/// `HertusCore` is re-exported, so `import Hertus` is the only import a host app
/// needs for the event types and the error vocabulary.
public enum Hertus {

    private static let runtime = HertusRuntime()

    /// Starts the SDK. Returns immediately.
    ///
    /// What happens after it returns: the SDK resolves its configuration and
    /// then starts Guard, if the switches allow it. `HertusConfig.onInitialized`
    /// fires when startup settles, including when it settles badly, so a host
    /// app waiting on it is never left waiting.
    ///
    /// Calling it a second time logs a warning and does nothing. The first
    /// configuration wins.
    public static func initialize(_ config: HertusConfig) {
        runtime.initialize(config)
    }

    /// Turns measurement off, or back on, at runtime.
    ///
    /// For an in-app privacy toggle. The setting is not persisted; a host app
    /// that offers the choice owns storing it and re-applies it after
    /// `initialize` on the next launch.
    public static func setEnabled(_ enabled: Bool) {
        runtime.setEnabled(enabled)
    }

    /// Whether the SDK is currently measuring.
    public static func isEnabled() -> Bool {
        runtime.isEnabled()
    }

    /// Whether Guard is running right now.
    ///
    /// False until startup settles, and false for the rest of the launch on a
    /// device the switches turned off. For a host app's own diagnostics; the
    /// reason it is false is in the log.
    public static func isGuardRunning() -> Bool {
        runtime.isGuardRunning
    }

    /// This SDK's version, for a host app's own diagnostics.
    public static func sdkVersion() -> String { SdkInfo.version }

    /// What the server is told this SDK runs on.
    public static func platform() -> String { SdkInfo.platform }
}
