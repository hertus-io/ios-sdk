import XCTest
@testable import HertusCore

final class EventParametersTests: XCTestCase {

    func testTheBuilderKeepsTypedValuesUnderTheirKeys() {
        let parameters = EventParameters.build {
            $0.put("text", "value")
            $0.put("count", 3)
            $0.put("ratio", 0.5)
            $0.put("flag", true)
        }

        XCTAssertEqual(parameters.count, 4)
        XCTAssertEqual(parameters["text"], .string("value"))
        XCTAssertEqual(parameters["count"], .long(3))
        XCTAssertEqual(parameters["ratio"], .double(0.5))
        XCTAssertEqual(parameters["flag"], .boolean(true))
    }

    func testLaterWritesWin() {
        let parameters = EventParameters.build {
            $0.put("k", "first")
            $0.put("k", "second")
        }

        XCTAssertEqual(parameters.count, 1)
        XCTAssertEqual(parameters["k"], .string("second"))
    }

    /// Overwriting must not move a parameter to the end, or a report's column
    /// order would depend on how many times a value was set.
    func testOverwritingKeepsTheOriginalPosition() {
        let parameters = EventParameters.build {
            $0.put("first", 1)
            $0.put("second", 2)
            $0.put("first", 99)
        }

        XCTAssertEqual(parameters.keys, ["first", "second"])
        XCTAssertEqual(parameters["first"], .long(99))
    }

    /// A refused parameter must never cost the event. A malformed figure is
    /// worth less than the fact that something happened.
    func testARefusedValueIsRecordedAndTheRestSurvive() {
        let parameters = EventParameters.build {
            $0.put("good", "kept")
            $0.put("bad", Double.nan)
        }

        XCTAssertEqual(parameters.count, 1)
        XCTAssertEqual(parameters["good"], .string("kept"))
        XCTAssertNil(parameters["bad"])
        XCTAssertEqual(parameters.rejections.count, 1)
        XCTAssertEqual(parameters.rejections.first?.key, "bad")
    }

    func testABlankKeyIsRefused() {
        let parameters = EventParameters.build { $0.put("   ", "value") }

        XCTAssertEqual(parameters.count, 0)
        XCTAssertEqual(parameters.rejections.count, 1)
        XCTAssertTrue(parameters.rejections[0].reason.contains("blank"))
    }

    func testKeysAreTrimmedSoAStraySpaceIsNotASecondParameter() {
        let parameters = EventParameters.build {
            $0.put(" k ", "a")
            $0.put("k", "b")
        }

        XCTAssertEqual(parameters.count, 1)
        XCTAssertEqual(parameters["k"], .string("b"))
    }

    func testAnOverLongKeyIsRefused() {
        let parameters = EventParameters.build {
            $0.put(String(repeating: "k", count: EventParameters.maxKeyLength + 1), "value")
        }

        XCTAssertEqual(parameters.count, 0)
        XCTAssertEqual(parameters.rejections.count, 1)
    }

    /// Bounded so one event cannot carry a database row into somebody's report.
    func testTheParameterCountIsCapped() {
        let parameters = EventParameters.build { builder in
            for index in 0..<(EventParameters.maxParameters + 10) {
                builder.put("k\(index)", index)
            }
        }

        XCTAssertEqual(parameters.count, EventParameters.maxParameters)
        XCTAssertEqual(parameters.rejections.count, 10)
    }

    /// Overwriting an existing key at the cap is not a new parameter.
    func testOverwritingAtTheCapStillWorks() {
        let parameters = EventParameters.build { builder in
            for index in 0..<EventParameters.maxParameters {
                builder.put("k\(index)", index)
            }
            builder.put("k0", "replaced")
        }

        XCTAssertEqual(parameters.count, EventParameters.maxParameters)
        XCTAssertEqual(parameters["k0"], .string("replaced"))
        XCTAssertTrue(parameters.rejections.isEmpty)
    }

    func testPutIfPresentIgnoresNilInsteadOfStoringAnEmptyParameter() {
        let parameters = EventParameters.build {
            $0.putIfPresent("a", nil as String?)
            $0.putIfPresent("b", nil as Int64?)
            $0.putIfPresent("c", nil as Double?)
            $0.putIfPresent("d", "present")
        }

        XCTAssertEqual(parameters.count, 1)
        XCTAssertTrue(parameters.contains("d"))
        XCTAssertTrue(parameters.rejections.isEmpty)
    }

    func testEmptyIsEmpty() {
        XCTAssertTrue(EventParameters.empty.isEmpty)
        XCTAssertEqual(EventParameters.empty.count, 0)
    }

    func testMergingCarriesRejectionsFromBothSidesAndLetsTheNewerWin() {
        let first = EventParameters.build {
            $0.put("a", 1)
            $0.put("bad", Double.nan)
        }
        let second = EventParameters.build {
            $0.put("a", 2)
            $0.put("b", 3)
        }
        let merged = first.merged(with: second)

        XCTAssertEqual(merged["a"], .long(2))
        XCTAssertEqual(merged["b"], .long(3))
        XCTAssertEqual(merged.rejections.count, 1)
    }

    func testContainsReportsOnlyWhatSurvived() {
        let parameters = EventParameters.build {
            $0.put("kept", 1)
            $0.put("dropped", Double.nan)
        }

        XCTAssertTrue(parameters.contains("kept"))
        XCTAssertFalse(parameters.contains("dropped"))
    }
}
