import Foundation

/// The one thing about a `HertusConfig` that is checked before any work is
/// scheduled.
///
/// A malformed token is a programming error rather than a runtime condition:
/// the developer is watching the console right now, and telling them
/// immediately is worth more than a round trip that will be rejected anyway.
/// Everything checked after this point is somebody's network being bad.
public enum AppToken {

    /// 64 lowercase hex characters, as minted by `apps.NewSdkKey` on the
    /// server.
    public static func isWellFormed(_ token: String) -> Bool {
        guard token.count == 64 else { return false }
        return token.allSatisfy { character in
            character.isASCII && (character.isNumber || ("a"..."f").contains(character))
        }
    }

    /// What to tell a developer whose token will not work.
    ///
    /// Names the dashboard path, because "invalid token" without one sends
    /// people to search documentation for a screen they have already seen.
    public static let malformedMessage =
        "app token is not 64 hex characters, so nothing will be measured. "
        + "Copy it from Developer tools -> SDK credentials."

    /// A token reduced to something safe to log.
    ///
    /// The token is public by construction and ships inside the app bundle, so
    /// this is about log hygiene rather than secrecy: a full token in a support
    /// ticket invites somebody to treat it as a credential.
    public static func redact(_ token: String) -> String {
        guard token.count >= 8 else { return "..." }
        return "...\(token.suffix(8))"
    }
}
