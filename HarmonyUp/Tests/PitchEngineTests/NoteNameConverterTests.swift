import XCTest
@testable import HarmonyUp

final class NoteNameConverterTests: XCTestCase {

    func testA4IsExact() {
        let result = NoteNameConverter.convert(frequency: 440.0)
        XCTAssertEqual(result?.noteName, "A4")
        XCTAssertEqual(result?.centsOffset ?? .infinity, 0.0, accuracy: 0.01)
    }

    func testMiddleC() {
        let result = NoteNameConverter.convert(frequency: 261.63)
        XCTAssertEqual(result?.noteName, "C4")
    }

    func testSlightlySharpA4ReportsPositiveCents() {
        // 440Hz보다 반음의 절반 정도 높은 주파수 -> 여전히 A4로 스냅되지만 양의 cent 편차를 가져야 한다.
        let sharpFrequency = 440.0 * pow(2.0, (25.0 / 100.0) / 12.0)
        let result = NoteNameConverter.convert(frequency: sharpFrequency)
        XCTAssertEqual(result?.noteName, "A4")
        XCTAssertEqual(result?.centsOffset ?? 0, 25.0, accuracy: 0.5)
    }

    func testZeroOrNegativeFrequencyReturnsNil() {
        XCTAssertNil(NoteNameConverter.convert(frequency: 0))
        XCTAssertNil(NoteNameConverter.convert(frequency: -10))
    }
}
