import XCTest
@testable import HertusCore

final class HertusEventTests: XCTestCase {

    // MARK: CustomEvent

    func testACustomEventKeepsTheNameItWasGiven() {
        let event = CustomEvent("level_complete") { $0.put("level", 12) }

        XCTAssertEqual(event.name, "level_complete")
        XCTAssertEqual(event.parameters["level"], .long(12))
        XCTAssertTrue(event.isWellFormed)
    }

    func testEveryDocumentedNameShapeIsAccepted() {
        for name in ["a", "level_complete", "checkout.started", "step-1", "A1"] {
            XCTAssertEqual(CustomEvent(name).name, name, "\(name) should be usable")
        }
    }

    /// Losing the name of one event beats taking down somebody's app over a
    /// typo in a string literal, so this replaces rather than throws.
    func testAnUnusableNameFallsBackAndIsRecorded() {
        for name in ["", "has space", "emoji 😀", String(repeating: "x", count: 65)] {
            let event = CustomEvent(name)
            XCTAssertEqual(event.name, CustomEvent.fallbackName)
            XCTAssertFalse(event.isWellFormed, "\(name) should not look well formed")
            XCTAssertEqual(event.rejections.first?.key, CustomEvent.nameField)
        }
    }

    func testAFallbackNameKeepsTheParametersThatWereFine() {
        let event = CustomEvent("not a valid name") { $0.put("kept", 1) }
        XCTAssertEqual(event.parameters["kept"], .long(1))
    }

    // MARK: RevenueEvent

    func testRevenueMapsItsTypedFieldsOntoTheContractKeys() {
        let event = RevenueEvent(amount: 4.99, currency: "USD", productId: "pro_monthly")

        XCTAssertEqual(event.name, RevenueEvent.wireName)
        XCTAssertEqual(event.parameters[EventFields.amount], .double(4.99))
        XCTAssertEqual(event.parameters[EventFields.currency], .string("USD"))
        XCTAssertEqual(event.parameters[EventFields.productId], .string("pro_monthly"))
        XCTAssertTrue(event.isWellFormed)
    }

    func testAnAbsentOptionalFieldIsAbsentRatherThanNull() {
        let event = RevenueEvent(amount: 1.0, currency: "EUR")

        XCTAssertFalse(event.parameters.contains(EventFields.productId))
        XCTAssertTrue(event.isWellFormed)
    }

    func testACurrencyThatIsNotIso4217IsRefusedAndTheEventSurvives() {
        for currency in ["usd", "US", "USDD", "$", "", "US1"] {
            let event = RevenueEvent(amount: 1.0, currency: currency)
            XCTAssertNil(event.parameters[EventFields.currency], "\(currency) should not reach the wire")
            XCTAssertEqual(event.parameters[EventFields.amount], .double(1.0))
            XCTAssertEqual(event.rejections.first?.key, EventFields.currency)
        }
    }

    /// A negative amount is almost always a refund the host app meant to report
    /// differently. Admitting it would put a negative row in a revenue total
    /// with nothing marking it deliberate.
    func testANegativeOrNonFiniteAmountIsRefused() {
        for amount in [-0.01, -100.0, Double.nan, Double.infinity] {
            let event = RevenueEvent(amount: amount, currency: "USD")
            XCTAssertNil(event.parameters[EventFields.amount], "\(amount) should not reach the wire")
            XCTAssertEqual(event.parameters[EventFields.currency], .string("USD"))
        }
    }

    func testZeroIsALegitimateAmount() {
        let event = RevenueEvent(amount: 0.0, currency: "USD")

        XCTAssertEqual(event.parameters[EventFields.amount], .double(0.0))
        XCTAssertTrue(event.isWellFormed)
    }

    /// A host app that puts "amount" in the extra map did not mean to overwrite
    /// the argument it also passed by name.
    func testATypedFieldWinsOverTheSameKeyInTheExtraMap() {
        let event = RevenueEvent(
            amount: 4.99,
            currency: "USD",
            additional: EventParameters.build {
                $0.put(EventFields.amount, 999.0)
                $0.put("extra", "kept")
            }
        )

        XCTAssertEqual(event.parameters[EventFields.amount], .double(4.99))
        XCTAssertEqual(event.parameters["extra"], .string("kept"))
    }

    // MARK: PurchaseEvent

    func testAPurchaseCarriesTheIdsTheServerNeedsToDeduplicate() {
        let event = PurchaseEvent(
            productId: "pro_monthly",
            amount: 4.99,
            currency: "USD",
            transactionId: "2000000123456789"
        )

        XCTAssertEqual(event.name, PurchaseEvent.wireName)
        XCTAssertEqual(event.parameters[EventFields.transactionId], .string("2000000123456789"))
        XCTAssertEqual(event.parameters[EventFields.productId], .string("pro_monthly"))
        XCTAssertTrue(event.isWellFormed)
    }

    /// Truncating a receipt leaves the server unable to verify a sale while
    /// every number upstream still looks right.
    func testAMultiKilobyteReceiptIsNotTruncatedAtTheOrdinaryStringLimit() {
        let receipt = String(repeating: "r", count: 8_000)
        let event = PurchaseEvent(
            productId: "p",
            amount: 1.0,
            currency: "USD",
            transactionId: "t",
            receipt: receipt
        )

        guard case .string(let stored)? = event.parameters[EventFields.receipt] else {
            return XCTFail("the receipt should have been stored")
        }
        XCTAssertEqual(stored.count, 8_000)
    }

    func testAReceiptBeyondEvenTheExemptionIsTruncatedRatherThanRefused() {
        let event = PurchaseEvent(
            productId: "p",
            amount: 1.0,
            currency: "USD",
            transactionId: "t",
            receipt: String(repeating: "r", count: EventFields.maxReceiptLength + 100)
        )

        guard case .string(let stored)? = event.parameters[EventFields.receipt] else {
            return XCTFail("the receipt should have been stored")
        }
        XCTAssertEqual(stored.count, EventFields.maxReceiptLength)
    }

    func testAnOverLongIdentifierIsTruncatedRatherThanRefused() {
        let event = PurchaseEvent(
            productId: String(repeating: "p", count: EventFields.maxIdentifierLength + 50),
            amount: 1.0,
            currency: "USD",
            transactionId: "t"
        )

        guard case .string(let stored)? = event.parameters[EventFields.productId] else {
            return XCTFail("the product id should have been stored")
        }
        XCTAssertEqual(stored.count, EventFields.maxIdentifierLength)
    }

    // MARK: SubscriptionEvent

    func testASubscriptionIsADistinctNameFromAPurchase() {
        let subscription = SubscriptionEvent(
            productId: "pro_annual",
            amount: 39.99,
            currency: "USD",
            transactionId: "t",
            periodDays: 365
        )

        XCTAssertEqual(subscription.name, SubscriptionEvent.wireName)
        XCTAssertNotEqual(
            subscription.name,
            PurchaseEvent.wireName,
            "renewals must not be counted as first purchases"
        )
        XCTAssertEqual(subscription.parameters[EventFields.periodDays], .long(365))
    }

    func testAnUnknownBillingPeriodIsSimplyAbsent() {
        let subscription = SubscriptionEvent(
            productId: "pro_annual",
            amount: 39.99,
            currency: "USD",
            transactionId: "t"
        )

        XCTAssertFalse(subscription.parameters.contains(EventFields.periodDays))
        XCTAssertTrue(subscription.isWellFormed)
    }

    // MARK: AdRevenueEvent

    func testAdRevenueCarriesItsMediationSource() {
        let event = AdRevenueEvent(
            source: "applovin_max",
            amount: 0.0031,
            currency: "USD",
            network: "meta",
            placement: "rewarded_end"
        )

        XCTAssertEqual(event.name, AdRevenueEvent.wireName)
        XCTAssertEqual(event.parameters[EventFields.source], .string("applovin_max"))
        XCTAssertEqual(event.parameters[EventFields.network], .string("meta"))
        XCTAssertEqual(event.parameters[EventFields.placement], .string("rewarded_end"))
    }

    func testTheVerySmallAmountsAdRevenueDealsInSurviveIntact() {
        let event = AdRevenueEvent(source: "s", amount: 0.0000031, currency: "USD")
        XCTAssertEqual(event.parameters[EventFields.amount], .double(0.0000031))
    }

    // MARK: the contract

    /// The property the whole design rests on. If a subclass ever reaches the
    /// wire as anything other than a name and a map, adding an event stops
    /// being free for the wrappers.
    func testEverySubclassPresentsTheSameTwoThings() {
        let events: [HertusEvent] = [
            CustomEvent("custom"),
            RevenueEvent(amount: 1.0, currency: "USD"),
            PurchaseEvent(productId: "p", amount: 1.0, currency: "USD", transactionId: "t"),
            SubscriptionEvent(productId: "p", amount: 1.0, currency: "USD", transactionId: "t"),
            AdRevenueEvent(source: "s", amount: 1.0, currency: "USD"),
        ]

        for event in events {
            XCTAssertFalse(event.name.isEmpty)
            XCTAssertTrue(
                EventFields.isValidEventName(event.name),
                "\(event.name) must be a name the contract allows"
            )
        }
        XCTAssertEqual(Set(events.map(\.name)).count, events.count, "names must be distinct")
    }

    func testDescriptionNamesTheClassWithoutDumpingParameterValues() {
        let event = RevenueEvent(amount: 4.99, currency: "USD")
        let text = event.description

        XCTAssertTrue(text.contains("RevenueEvent"))
        XCTAssertTrue(text.contains(RevenueEvent.wireName))
        XCTAssertFalse(text.contains("4.99"), "parameter values do not belong in a log line")
    }
}
