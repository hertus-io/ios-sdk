import Foundation

/// Something the SDK could not do.
///
/// Conforms to `Error` so it can be thrown by host-app code that wants to, but
/// the SDK itself never throws one into a caller: it hands them to
/// `HertusConfig.onError`. A measurement library sitting in somebody's startup
/// path does not get to interrupt it.
///
/// The message is the code's fixed text. An engine's own wording never reaches
/// it, because that wording names the vendor.
public struct HertusError: Error, Equatable, CustomStringConvertible {

    public let code: HertusErrorCode

    /// Fixed per code. Safe to show a developer, never shown to a user.
    public var message: String { code.message }

    /// The wire value, which is the string worth searching for.
    public var wireValue: String { code.wireValue }

    public init(code: HertusErrorCode) {
        self.code = code
    }

    public var description: String { "HertusError(\(code.wireValue)): \(message)" }
}

extension HertusError: LocalizedError {
    public var errorDescription: String? { message }
}
