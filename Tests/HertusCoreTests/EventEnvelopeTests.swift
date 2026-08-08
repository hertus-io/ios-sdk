import XCTest
@testable import HertusCore

final class EventEnvelopeTests: XCTestCase {

    private func json(_ event: HertusEvent) -> [String: Any] {
        event.envelope(eventId: "test-id", occurredAtMillis: 1_700_000_000_000).jsonObject()
    }

    private func parameters(_ event: HertusEvent) -> [String: Any] {
        json(event)[EventEnvelope.fieldParameters] as? [String: Any] ?? [:]
    }

    func testTheEnvelopeCarriesTheFiveContractFields() {
        let object = json(RevenueEvent(amount: 4.99, currency: "USD"))

        XCTAssertEqual(object[EventEnvelope.fieldSchemaVersion] as? Int, EventEnvelope.schemaVersion)
        XCTAssertEqual(object[EventEnvelope.fieldName] as? String, RevenueEvent.wireName)
        XCTAssertEqual(object[EventEnvelope.fieldEventId] as? String, "test-id")
        XCTAssertEqual(object[EventEnvelope.fieldOccurredAt] as? Int64, 1_700_000_000_000)
        XCTAssertNotNil(object[EventEnvelope.fieldParameters])
    }

    /// Parameters serialize as ordinary JSON values, not as tagged objects. The
    /// alternative doubles the size of the most numerous payload the SDK sends.
    func testParametersSerializeAsPlainJsonValues() {
        let event = CustomEvent("mixed") {
            $0.put("text", "value")
            $0.put("count", 3)
            $0.put("ratio", 0.5)
            $0.put("flag", true)
        }

        let encoded = parameters(event)
        XCTAssertEqual(encoded["text"] as? String, "value")
        XCTAssertEqual(encoded["count"] as? Int64, 3)
        XCTAssertEqual(encoded["ratio"] as? Double, 0.5)
        XCTAssertEqual(encoded["flag"] as? Bool, true)
    }

    func testAnEventWithNoParametersStillCarriesAnEmptyObject() {
        XCTAssertEqual(parameters(CustomEvent("bare")).count, 0)
    }

    func testARefusedParameterIsAbsentFromTheWireForm() {
        let event = CustomEvent("partly_bad") {
            $0.put("good", 1)
            $0.put("bad", Double.nan)
        }

        let encoded = parameters(event)
        XCTAssertEqual(encoded.count, 1)
        XCTAssertNotNil(encoded["good"])
        XCTAssertNil(encoded["bad"], "a refused value must not reach the server")
    }

    /// The property that makes a new event class free for the wrappers: nothing
    /// downstream can tell which subclass produced an envelope.
    func testTwoDifferentClassesProduceStructurallyIdenticalEnvelopes() {
        let custom = json(CustomEvent("hertus.revenue") { $0.put("amount", 4.99) })
        let typed = json(RevenueEvent(amount: 4.99, currency: "USD"))

        XCTAssertEqual(Set(custom.keys), Set(typed.keys))
        XCTAssertEqual(
            custom[EventEnvelope.fieldName] as? String,
            typed[EventEnvelope.fieldName] as? String
        )
    }

    func testTheReceiptSurvivesSerializationWhole() {
        let receipt = String(repeating: "r", count: 8_000)
        let event = PurchaseEvent(
            productId: "p",
            amount: 1.0,
            currency: "USD",
            transactionId: "t",
            receipt: receipt
        )

        XCTAssertEqual(parameters(event)[EventFields.receipt] as? String, receipt)
    }

    func testTextNeedingEscapingRoundTrips() {
        let awkward = "quote \" backslash \\ newline \n unicode ç"
        let event = CustomEvent("escaping") { $0.put("text", awkward) }

        guard let text = event.envelope(eventId: "id", occurredAtMillis: 1).jsonString(),
              let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encoded = parsed[EventEnvelope.fieldParameters] as? [String: Any]
        else {
            return XCTFail("the envelope should have serialized")
        }

        XCTAssertEqual(encoded["text"] as? String, awkward)
    }

    func testTheEnvelopeSerializesToValidJson() {
        let event = RevenueEvent(amount: 4.99, currency: "USD", productId: "pro")
        guard let text = event.envelope(eventId: "id", occurredAtMillis: 1).jsonString() else {
            return XCTFail("the envelope should have serialized")
        }

        let data = Data(text.utf8)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    func testTheEventIdIsCarriedThroughUnchanged() {
        let envelope = CustomEvent("x").envelope(eventId: "a-b-c-d", occurredAtMillis: 1)

        XCTAssertEqual(envelope.eventId, "a-b-c-d")
        XCTAssertEqual(envelope.jsonObject()[EventEnvelope.fieldEventId] as? String, "a-b-c-d")
    }

    func testDescriptionOmitsParameterValues() {
        let envelope = CustomEvent("x") { $0.put("secret", "value") }
            .envelope(eventId: "id", occurredAtMillis: 1)

        XCTAssertFalse(envelope.description.contains("value"))
    }
}
