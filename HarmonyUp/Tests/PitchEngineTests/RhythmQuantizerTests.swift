import XCTest
@testable import HarmonyUp

final class RhythmQuantizerTests: XCTestCase {

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(RhythmQuantizer.quantize(durations: []).isEmpty)
    }

    // 전부 같은 길이면 중앙값도 그 값이라, 전부 "1박(4분음표)"로 분류돼야 한다.
    func testUniformDurationsAllBecomeQuarterNotes() {
        let result = RhythmQuantizer.quantize(durations: [0.3, 0.3, 0.3, 0.3])
        XCTAssertTrue(result.allSatisfy { $0.vexFlowDuration == "q" })
    }

    // 중앙값(0.3) 대비 절반 이하로 짧은 음은 8분음표로 분류돼야 한다.
    func testShortNoteRelativeToMedianBecomesEighthNote() {
        let result = RhythmQuantizer.quantize(durations: [0.3, 0.3, 0.3, 0.1])
        XCTAssertEqual(result.last?.vexFlowDuration, "8")
        XCTAssertEqual(result.last?.beats, 0.5)
    }

    // 중앙값 대비 2배 이상 긴 음은 2분음표로 분류돼야 한다.
    func testLongNoteRelativeToMedianBecomesHalfNote() {
        let result = RhythmQuantizer.quantize(durations: [0.3, 0.3, 0.3, 0.7])
        XCTAssertEqual(result.last?.vexFlowDuration, "h")
        XCTAssertEqual(result.last?.beats, 2.0)
    }

    func testOrderIsPreserved() {
        let result = RhythmQuantizer.quantize(durations: [0.1, 0.7, 0.3])
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].vexFlowDuration, "8")
        XCTAssertEqual(result[1].vexFlowDuration, "h")
        XCTAssertEqual(result[2].vexFlowDuration, "q")
    }

    // 4박(4/4박자 한 마디)이 꽉 차는 지점마다 마디가 끊겨야 한다 — 4분음표 4개 = 정확히 마디 하나.
    func testMeasureBreaksAtExactlyFourBeats() {
        let notes = RhythmQuantizer.quantize(durations: [0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3])
        let breaks = RhythmQuantizer.measureBreaks(notes: notes)
        XCTAssertEqual(breaks, [4, 4])
    }

    // 마지막 마디가 4박을 못 채우고 끝나도(녹음이 마디 중간에서 끝남) 남은 음들은 마지막
    // 마디로 그대로 들어가야 한다 — 버려지는 음이 없어야 한다.
    func testTrailingIncompleteMeasureIsKept() {
        let notes = RhythmQuantizer.quantize(durations: [0.3, 0.3, 0.3, 0.3, 0.3])
        let breaks = RhythmQuantizer.measureBreaks(notes: notes)
        XCTAssertEqual(breaks, [4, 1])
        XCTAssertEqual(breaks.reduce(0, +), notes.count)
    }

    func testMeasureBreaksOnEmptyInputReturnsEmpty() {
        XCTAssertTrue(RhythmQuantizer.measureBreaks(notes: []).isEmpty)
    }
}
