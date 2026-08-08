import Foundation

/// Something worth measuring that happened in the host app.
///
/// A class hierarchy with one subclass per event the platform reports on
/// specially, and `CustomEvent` as the escape hatch for everything else. A host
/// app that needs an event this hierarchy does not model uses `CustomEvent`
/// rather than subclassing, because a subclass the SDK has never heard of would
/// serialize to a name the server cannot report on.
///
/// ```swift
/// Hertus.track(RevenueEvent(amount: 4.99, currency: "USD", productId: "pro_monthly"))
/// ```
///
/// **Every subclass is a constructor, not a protocol.** They all serialize to
/// the same envelope: a name and a map. Nothing downstream, including the
/// bridge into Flutter or Unity, learns that `RevenueEvent` exists. That is
/// what lets a new event type ship without a new native release. See
/// `sdk/contract/events.yaml`.
///
/// A class rather than a protocol so the shared behaviour has one
/// implementation, and so the hierarchy reads the same way it does in Kotlin.
/// `public` rather than `open`, which is how Swift spells a closed hierarchy:
/// a host app cannot add a case, matching the Kotlin `sealed class`.
public class HertusEvent {

    /// The name this event appears under in reports.
    public let name: String

    /// The detail carried alongside `name`.
    public let parameters: EventParameters

    /// Not public: the set of events is the contract's to decide, and a
    /// subclass declared in a host app would serialize to a name the server
    /// cannot report on.
    init(name: String, parameters: EventParameters) {
        self.name = name
        self.parameters = parameters
    }

    /// Parameters that did not survive validation, and why.
    ///
    /// Empty for a well-formed event. The SDK logs these once when the event is
    /// tracked; they are exposed here so a host app's own tests can assert on
    /// them rather than reading a console.
    public var rejections: [EventParameters.Rejection] { parameters.rejections }

    /// True when every parameter this event was given survived validation.
    public var isWellFormed: Bool { parameters.rejections.isEmpty }

    /// The wire form. Identical in shape for every subclass, which is the whole
    /// point of the hierarchy.
    ///
    /// Identity and timing are arguments rather than host-app properties: an
    /// event whose id the caller chose could be replayed, and one whose
    /// timestamp it chose could be backdated past a billing boundary, so the
    /// SDK supplies both.
    public func envelope(eventId: String, occurredAtMillis: Int64) -> EventEnvelope {
        EventEnvelope(
            name: name,
            parameters: parameters,
            eventId: eventId,
            occurredAtMillis: occurredAtMillis
        )
    }
}

extension HertusEvent: CustomStringConvertible {
    /// Names the class without dumping parameter values, because this is what
    /// ends up in a log line somebody pastes into a support ticket.
    public var description: String {
        "\(type(of: self))(name=\(name), \(parameters.count) parameter(s))"
    }
}
