import Foundation

/// An event the host app names itself.
///
/// The escape hatch, and the one most apps use most. Everything the typed
/// subclasses do could be done with this; they exist so that the events the
/// platform reports on specially are spelled the same way by every customer.
///
/// ```swift
/// Hertus.track(
///     CustomEvent("level_complete") {
///         $0.put("level", 12)
///         $0.put("duration_seconds", 94.5)
///     }
/// )
/// ```
///
/// A name that does not match `[a-zA-Z0-9_.-]{1,64}` becomes `fallbackName` and
/// is recorded in `rejections`. Losing the name of one event is better than
/// taking down somebody's app over a typo in a string literal.
public final class CustomEvent: HertusEvent {

    /// What an unusable name becomes. Deliberately conspicuous: a customer
    /// seeing a column of these in a report has a specific thing to search
    /// their own source for.
    public static let fallbackName = "hertus.invalid_name"

    /// The rejection key used when the name itself was the problem.
    public static let nameField = "name"

    public init(_ name: String, parameters: EventParameters = .empty) {
        let usable = EventFields.isValidEventName(name)

        let resolved: EventParameters
        if usable {
            resolved = parameters
        } else {
            var builder = EventParameters.Builder()
            builder.putAll(parameters)
            builder.putRefused(
                CustomEvent.nameField,
                "not a usable event name, so \(CustomEvent.fallbackName) was sent instead"
            )
            resolved = builder.build()
        }

        super.init(
            name: usable ? name : CustomEvent.fallbackName,
            parameters: resolved
        )
    }

    /// The closure form, so parameters can be written inline at the call site.
    public convenience init(_ name: String, _ configure: (inout EventParameters.Builder) -> Void) {
        self.init(name, parameters: EventParameters.build(configure))
    }
}
