import Foundation

/// A value an event parameter may hold.
///
/// The set is closed on purpose. A parameter typed as `Any` serializes
/// differently in every language this SDK is bound into, and the difference
/// only surfaces once somebody's report has a column of nulls in it.
///
/// An `enum` rather than a class hierarchy, which is what the Kotlin sealed
/// class means in Swift: it makes a `switch` exhaustive and keeps a value that
/// exists a value that can be sent. Construct through `of`, which applies the
/// limits in `sdk/contract/values.yaml`.
public enum HertusValue: Equatable {

    case string(String)
    case long(Int64)
    case double(Double)
    case boolean(Bool)

    /// Longer than any label a report can usefully show, short enough that a
    /// host app cannot post a log file one parameter at a time.
    public static let maxStringLength = 1024

    /// This value's type as it appears on the wire. Stable, and part of the
    /// contract. Used by the bridges, where the host language needs the type
    /// spelled out; the wire itself relies on JSON's own types.
    public var typeKey: String {
        switch self {
        case .string: return "string"
        case .long: return "long"
        case .double: return "double"
        case .boolean: return "boolean"
        }
    }

    /// Truncates past `maxStringLength` rather than refusing.
    public static func of(_ value: String) -> HertusValue {
        .string(value.count <= maxStringLength ? value : String(value.prefix(maxStringLength)))
    }

    public static func of(_ value: Int64) -> HertusValue { .long(value) }

    public static func of(_ value: Int) -> HertusValue { .long(Int64(value)) }

    /// Nil for NaN and both infinities, which have no JSON representation and
    /// would otherwise be discovered by the server rather than here.
    public static func of(_ value: Double) -> HertusValue? {
        value.isFinite ? .double(value) : nil
    }

    public static func of(_ value: Bool) -> HertusValue { .boolean(value) }

    /// Text held to a limit other than `maxStringLength`.
    ///
    /// Internal, and used for the one field that needs it: a store receipt runs
    /// to several kilobytes, and truncating it at the ordinary limit would
    /// leave the server unable to verify a sale while everything upstream still
    /// looked correct.
    static func ofText(_ value: String, maxLength: Int) -> HertusValue {
        .string(value.count <= maxLength ? value : String(value.prefix(maxLength)))
    }

    /// The payload, in the plainest form the transport can carry.
    var wireValue: Any {
        switch self {
        case .string(let value): return value
        case .long(let value): return value
        case .double(let value): return value
        case .boolean(let value): return value
        }
    }
}

extension HertusValue: CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let value): return value
        case .long(let value): return String(value)
        case .double(let value): return String(value)
        case .boolean(let value): return String(value)
        }
    }
}
