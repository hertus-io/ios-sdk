import Foundation

/// Which Hertus environment an app reports to.
///
/// The value reaches the wire as `wireValue`, so these strings match the
/// `sdk/<dir>` keys the dashboard already uses and the ones the Android SDK
/// sends. Renaming one is a change to the server, not an edit here.
public enum HertusEnvironment: String, CaseIterable {

    /// Real measurement, real billing, Guard governed by the server.
    case production

    /// A developer's own device. Guard does not identify here unless asked; see
    /// `HertusConfig.guardInSandbox`.
    case sandbox

    /// What the server is told.
    public var wireValue: String { rawValue }

    /// Resolves a wire value, or nil. Wrapper SDKs parse rather than guess.
    public static func fromWireValue(_ value: String) -> HertusEnvironment? {
        HertusEnvironment(rawValue: value)
    }
}
