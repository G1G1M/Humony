import XCTest
@testable import Humony

final class PracticeSummaryTests: XCTestCase {

    func testEmptyScoresReturnsNil() {
        XCTAssertNil(PracticeSummary.aggregate(scores: []))
    }

    func testAllOnPitchGivesRatioOne() throws {
        let scores = [
            PitchScorer.Score(centsOffset: 2, isOnPitch: true),
            PitchScorer.Score(centsOffset: -5, isOnPitch: true),
            PitchScorer.Score(centsOffset: 0, isOnPitch: true)
        ]
        let result = try XCTUnwrap(PracticeSummary.aggregate(scores: scores))

        XCTAssertEqual(result.sampleCount, 3)
        XCTAssertEqual(result.onPitchRatio, 1.0, accuracy: 0.001)
    }

    func testMixedAccuracyComputesCorrectRatioAndAverage() throws {
        let scores = [
            PitchScorer.Score(centsOffset: 10, isOnPitch: true),
            PitchScorer.Score(centsOffset: -60, isOnPitch: false),
            PitchScorer.Score(centsOffset: 40, isOnPitch: false),
            PitchScorer.Score(centsOffset: -10, isOnPitch: true)
        ]
        let result = try XCTUnwrap(PracticeSummary.aggregate(scores: scores))

        XCTAssertEqual(result.sampleCount, 4)
        XCTAssertEqual(result.onPitchRatio, 0.5, accuracy: 0.001)
        // 부호를 무시한 평균: (10 + 60 + 40 + 10) / 4 = 30
        XCTAssertEqual(result.averageAbsCentsOffset, 30.0, accuracy: 0.001)
    }
}
