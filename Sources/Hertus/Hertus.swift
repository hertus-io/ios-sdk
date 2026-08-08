@_exported import HertusCore
import Foundation

/// The Hertus SDK.
///
/// ```swift
/// let config = HertusConfig(appToken: Secrets.hertusToken, environment: .production)
/// Hertus.initialize(config)
/// ```
///
/// A namespace rather than an instantiable object, because there is one device
/// and one app, and an SDK that could be created twice would let two instances
/// race over the same cache and the same identification quota. The logic lives
/// in ordinary types behind it, so that being a singleton is a property of the
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

    /// This SDK's version, for a host app's own diagnostics.
    public static func sdkVersion() -> String { SdkInfo.version }

    /// What the server is told this SDK runs on.
    public static func platform() -> String { SdkInfo.platform }
}
