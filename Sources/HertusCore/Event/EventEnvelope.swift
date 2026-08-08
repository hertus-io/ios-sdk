import Foundation

/// The wire form of any event. One shape, whatever class produced it.
///
/// This is the only event shape the bridge and the ingest path know about, and
/// the reason a new event class costs no native code: `RevenueEvent` and
/// `CustomEvent` arrive here indistinguishable apart from their `name`.
public struct EventEnvelope {

    /// Bumped when this envelope changes shape, never when an event is added.
    ///
    /// A reader that does not recognise the version keeps what it understands
    /// and ignores the rest, so a newer wrapper against an older native SDK
    /// degrades rather than failing. See `sdk/contract/bridge.yaml`.
    public static let schemaVersion = 1

    public static let fieldSchemaVersion = "schemaVersion"
    public static let fieldName = "name"
    public static let fieldEventId = "eventId"
    public static let fieldOccurredAt = "occurredAtMillis"
    public static let fieldParameters = "parameters"

    public let name: String
    public let parameters: EventParameters

    /// Chosen on the device so a retried upload is recognisable as the same
    /// event. Without it, at-least-once delivery becomes duplicated revenue.
    public let eventId: String

    /// Device clock, milliseconds since the epoch.
    ///
    /// Device clocks are wrong often enough that the server treats this as a
    /// claim rather than a fact and stamps its own receipt time alongside it.
    public let occurredAtMillis: Int64

    init(name: String, parameters: EventParameters, eventId: String, occurredAtMillis: Int64) {
        self.name = name
        self.parameters = parameters
        self.eventId = eventId
        self.occurredAtMillis = occurredAtMillis
    }

    /// The envelope as a JSON object, ready to serialize.
    ///
    /// Parameters appear as ordinary JSON values rather than as tagged objects.
    /// JSON's own types carry everything the server needs, and the alternative
    /// would double the size of the most numerous payload the SDK sends.
    /// `HertusValue.typeKey` exists for the bridges instead, where the host
    /// language does need the type spelled out.
    public func jsonObject() -> [String: Any] {
        var encodedParameters: [String: Any] = [:]
        for entry in parameters.storage {
            encodedParameters[entry.key] = entry.value.wireValue
        }

        return [
            EventEnvelope.fieldSchemaVersion: EventEnvelope.schemaVersion,
            EventEnvelope.fieldName: name,
            EventEnvelope.fieldEventId: eventId,
            EventEnvelope.fieldOccurredAt: occurredAtMillis,
            EventEnvelope.fieldParameters: encodedParameters,
        ]
    }

    /// The envelope as JSON text.
    ///
    /// Returns nil only if Foundation refuses the object, which cannot happen
    /// for the closed set of types `HertusValue` admits. Nil rather than a
    /// throw because a serialization failure is the SDK's bug and must not
    /// reach a host app as an exception.
    public func jsonString() -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject()) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension EventEnvelope: CustomStringConvertible {
    public var description: String {
        "EventEnvelope(name=\(name), id=\(eventId), \(parameters.count) parameter(s))"
    }
}
