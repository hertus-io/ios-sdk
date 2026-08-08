import Foundation

/// Which server the SDK talks to.
///
/// An origin, never a base path: the SDK appends the versioned API path itself,
/// so the endpoint survives the API being versioned without every host app
/// editing a string.
public enum ServerEndpoints {

    static let production = "https://api.hertus.io"
    static let sandbox = "https://api-sandbox.hertus.io"

    public static func defaultFor(_ environment: HertusEnvironment) -> String {
        switch environment {
        case .production: return production
        case .sandbox: return sandbox
        }
    }

    /// What the SDK will actually use, and whether an override was rejected on
    /// the way here.
    ///
    /// Reported rather than silently applied, because falling back quietly
    /// would leave a developer pointing the sample app at their laptop and
    /// wondering why the requests went to production.
    public struct Resolution: Equatable {
        public let url: String
        public let refusedOverride: Bool
    }

    public static func resolve(
        override: String?,
        environment: HertusEnvironment
    ) -> Resolution {
        guard let override else {
            return Resolution(url: defaultFor(environment), refusedOverride: false)
        }
        if let accepted = UrlPolicy.accept(override, environment: environment) {
            return Resolution(url: accepted, refusedOverride: false)
        }
        return Resolution(url: defaultFor(environment), refusedOverride: true)
    }
}
