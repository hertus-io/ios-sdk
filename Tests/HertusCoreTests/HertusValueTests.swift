import XCTest
@testable import HertusCore

final class HertusValueTests: XCTestCase {

    func testEachFactoryProducesItsOwnCase() {
        XCTAssertEqual(HertusValue.of("text"), .string("text"))
        XCTAssertEqual(HertusValue.of(Int64(7)), .long(7))
        XCTAssertEqual(HertusValue.of(1.5), .double(1.5))
        XCTAssertEqual(HertusValue.of(true), .boolean(true))
    }

    /// An `Int` is the type a caller actually writes; widening it here keeps the
    /// call site clean.
    func testIntIsStoredAsLongRatherThanRefused() {
        XCTAssertEqual(HertusValue.of(7), .long(7))
    }

    func testOverLongTextIsTruncatedRatherThanRefused() {
        let value = HertusValue.of(String(repeating: "a", count: HertusValue.maxStringLength + 500))
        guard case .string(let text) = value else { return XCTFail("expected a string") }
        XCTAssertEqual(text.count, HertusValue.maxStringLength)
    }

    func testTextAtTheLimitIsLeftAlone() {
        let exact = String(repeating: "a", count: HertusValue.maxStringLength)
        XCTAssertEqual(HertusValue.of(exact), .string(exact))
    }

    /// NaN and the infinities have no JSON representation. Refusing here means
    /// the developer finds out at the call site instead of the server finding
    /// out later.
    func testValuesWithNoJsonFormAreRefused() {
        XCTAssertNil(HertusValue.of(Double.nan))
        XCTAssertNil(HertusValue.of(Double.infinity))
        XCTAssertNil(HertusValue.of(-Double.infinity))
        XCTAssertNotNil(HertusValue.of(0.0))
        XCTAssertNotNil(HertusValue.of(-1.5))
    }

    func testReceiptSizedStringSurvivesTheExemption() {
        let receipt = String(repeating: "r", count: 10_000)
        let value = HertusValue.ofText(receipt, maxLength: EventFields.maxReceiptLength)
        guard case .string(let text) = value else { return XCTFail("expected a string") }
        XCTAssertEqual(text.count, 10_000)
    }

    func testEqualityIsByValueSoTestsCanAssertOnParameters() {
        XCTAssertEqual(HertusValue.of("x"), HertusValue.of("x"))
        XCTAssertEqual(HertusValue.of(Int64(3)), HertusValue.of(3))
        XCTAssertNotEqual(HertusValue.of("x"), HertusValue.of("y"))
        XCTAssertNotEqual(HertusValue.of(Int64(1)), HertusValue.of(true))
    }

    func testTypeKeysAreTheOnesTheContractDeclares() {
        XCTAssertEqual(HertusValue.of("x").typeKey, "string")
        XCTAssertEqual(HertusValue.of(Int64(1)).typeKey, "long")
        XCTAssertEqual(HertusValue.of(1.5)?.typeKey, "double")
        XCTAssertEqual(HertusValue.of(true).typeKey, "boolean")
    }
}
