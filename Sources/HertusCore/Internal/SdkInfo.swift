import Foundation

/// Facts about this build, in one place so that nothing carries a second copy.
public enum SdkInfo {

    /// Reported to the server on every bootstrap and to the engine as
    /// integration metadata, so it is the string a support conversation starts
    /// from.
    public static let version = "1.0.0"

    /// What the server is told this SDK runs on.
    ///
    /// `ios` for every Apple platform the package builds for, matching the
    /// decision in docs/SDK.md that `platform` describes the native runtime
    /// rather than the binding language. A wrapper adds its own `wrapper` field
    /// instead of overloading this one.
    public static let platform = "ios"
}
