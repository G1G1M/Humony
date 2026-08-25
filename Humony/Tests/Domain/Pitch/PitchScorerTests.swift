import XCTest
@testable import Humony

final class PitchScorerTests: XCTestCase {

    func testExactMatchIsZeroCentsAndOnPitch() throws {
        let score = try XCTUnwrap(PitchScorer.score(sungFrequency: 440.0, targetFrequency: 440.0))
        XCTAssertEqual(score.centsOffset, 0, accuracy: 0.01)
        XCTAssertTrue(score.isOnPitch)
    }

    func testSlightlySharpIsPositiveAndWithinTolerance() throws {
        // 목표보다 20 cent 높게 부른 경우 — 허용오차(35 cent) 이내라 정확 판정이어야 한다.
        let sharpFrequency = 440.0 * pow(2.0, (20.0 / 100.0) / 12.0)
        let score = try XCTUnwrap(PitchScorer.score(sungFrequency: sharpFrequency, targetFrequency: 440.0))
        XCTAssertEqual(score.centsOffset, 20.0, accuracy: 0.5)
        XCTAssertTrue(score.isOnPitch)
    }

    func testFarOffPitchIsFlagged() throws {
        // 반음(100 cent)이나 벗어나면 명백히 다른 음이므로 벗어남으로 판정돼야 한다.
        let flatFrequency = 440.0 * pow(2.0, -100.0 / 100.0 / 12.0)
        let score = try XCTUnwrap(PitchScorer.score(sungFrequency: flatFrequency, targetFrequency: 440.0))
        XCTAssertFalse(score.isOnPitch)
        XCTAssertLessThan(score.centsOffset, -35.0)
    }

    func testInvalidFrequenciesReturnNil() {
        XCTAssertNil(PitchScorer.score(sungFrequency: 0, targetFrequency: 440.0))
        XCTAssertNil(PitchScorer.score(sungFrequency: 440.0, targetFrequency: 0))
        XCTAssertNil(PitchScorer.score(sungFrequency: -10, targetFrequency: 440.0))
    }
}
