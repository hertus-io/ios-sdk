import Foundation

/// The one thing about a `HertusConfig` that is checked before any work is
/// scheduled.
///
/// A malformed token is a programming error rather than a runtime condition:
/// the developer is watching the console right now, and telling them
/// immediately is worth more than a round trip that will be rejected anyway.
/// Everything checked after this point is somebody's network being bad.
///
/// A token names its environment:
///
/// ```
/// sk_prod_<64 hex>
/// sk_sandbox_<64 hex>
/// ```
///
/// The prefix is a label, not a decision. The server looks the whole token up
/// and reads the environment off the row it finds, so editing the prefix does
/// not move a build between environments — it produces a token that matches
/// nothing. What it buys is that "which environment is this build reporting to"
/// is answerable from a build config, a diff or a support ticket, which in 64
/// characters of undifferentiated hex it was not.
///
/// This replaced a bare 64-hex token. The old form is refused rather than
/// treated as production, deliberately: a bare token means a build predating
/// the change, and quietly giving it an environment nobody chose is exactly the
/// class of mistake the prefix exists to prevent.
public enum AppToken {

    private static let productionPrefix = "sk_prod_"
    private static let sandboxPrefix = "sk_sandbox_"
    private static let secretLength = 64

    /// An environment prefix followed by 64 lowercase hex characters.
    public static func isWellFormed(_ token: String) -> Bool {
        secret(of: token) != nil
    }

    /// The environment this token reports to, or nil if it is not a token.
    ///
    /// Read from the prefix rather than configured separately, so a build
    /// cannot hold a production token and a sandbox setting at the same time.
    /// That combination used to be expressible and there was no way for either
    /// side to notice.
    public static func environment(of token: String) -> HertusEnvironment? {
        guard isWellFormed(token) else { return nil }
        return token.hasPrefix(sandboxPrefix) ? .sandbox : .production
    }

    /// What to tell a developer whose token will not work.
    ///
    /// Names the dashboard path, because "invalid token" without one sends
    /// people to search documentation for a screen they have already seen.
    /// Names the shape too, because the commonest way to arrive here is now
    /// pasting the secret half without its prefix.
    public static let malformedMessage =
        "app token is not in the form sk_prod_<64 hex> or sk_sandbox_<64 hex>, so nothing "
        + "will be measured. Copy the whole token, prefix included, from "
        + "Developer tools -> SDK credentials."

    /// A token reduced to something safe to log.
    ///
    /// The token is public by construction and ships inside the app bundle, so
    /// this is about log hygiene rather than secrecy: a full token in a support
    /// ticket invites somebody to treat it as a credential.
    ///
    /// The prefix survives. It is the part that answers the question somebody
    /// reading the line is actually asking, and it is not the secret.
    public static func redact(_ token: String) -> String {
        guard let hex = secret(of: token) else { return "…" }
        let prefix = token.hasPrefix(sandboxPrefix) ? sandboxPrefix : productionPrefix
        return "\(prefix)…\(hex.suffix(4))"
    }

    /// The hex half, or nil when this is not a token.
    ///
    /// Sandbox is tested first: `sk_sandbox_` and `sk_prod_` share no prefix,
    /// so the order is not load-bearing, but checking the longer one first
    /// keeps it that way if a third environment ever arrives.
    private static func secret(of token: String) -> Substring? {
        let candidate: Substring
        if token.hasPrefix(sandboxPrefix) {
            candidate = token.dropFirst(sandboxPrefix.count)
        } else if token.hasPrefix(productionPrefix) {
            candidate = token.dropFirst(productionPrefix.count)
        } else {
            return nil
        }

        guard candidate.count == secretLength else { return nil }
        let isHex = candidate.allSatisfy { character in
            character.isASCII && (character.isNumber || ("a"..."f").contains(character))
        }
        return isHex ? candidate : nil
    }
}
