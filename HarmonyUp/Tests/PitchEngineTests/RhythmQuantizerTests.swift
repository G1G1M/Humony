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

    // 한 마디에 4박을 "넘겨서" 담으면 안 된다 — 4/4로 표기해놓고 실제로는 5박이 든 마디가
    // 그려지던 버그(136절). 4분음표 3개(3박) 다음에 2분음표(2박)가 오면 누적 5박이 되는데,
    // 예전 구현은 "누적이 4박 이상이면 끊는다"라서 그 2분음표까지 같은 마디에 밀어넣었다.
    // 4박을 넘기는 음은 다음 마디의 첫 음이 돼야 한다.
    func testNoteThatOverflowsMeasureMovesToNextMeasure() {
        let notes = RhythmQuantizer.quantize(durations: [0.3, 0.3, 0.3, 0.7])
        XCTAssertEqual(notes.map(\.beats), [1.0, 1.0, 1.0, 2.0]) // 전제 확인
        let breaks = RhythmQuantizer.measureBreaks(notes: notes)
        XCTAssertEqual(breaks, [3, 1])
    }

    // 8분음표가 섞여 마디 경계가 4박에 딱 안 떨어지는 경우도 마찬가지 — 3.5박까지 채운 뒤
    // 다음 4분음표(1박)를 더하면 4.5박이 되므로 그 음은 다음 마디로 넘겨야 한다.
    func testEighthAndQuarterMixNeverExceedsFourBeats() {
        let notes = RhythmQuantizer.quantize(durations: [0.3, 0.3, 0.3, 0.45, 0.45, 0.45])
        XCTAssertEqual(notes.map(\.beats), [0.5, 0.5, 0.5, 1.0, 1.0, 1.0]) // 전제 확인
        let breaks = RhythmQuantizer.measureBreaks(notes: notes)
        XCTAssertEqual(breaks, [5, 1])
    }

    // 어떤 조합이 들어와도 마디마다 박 합이 4박 이하여야 한다는 불변식 — 위 두 케이스를
    // 일반화한 것. 마디 구성이 바뀌어도 이 성질만은 깨지면 안 된다.
    func testEveryMeasureHoldsAtMostFourBeats() {
        let notes = RhythmQuantizer.quantize(durations: [0.2, 0.4, 0.4, 0.6, 0.4, 0.4, 0.8, 0.4, 0.4, 0.4])
        let breaks = RhythmQuantizer.measureBreaks(notes: notes)
        XCTAssertEqual(breaks.reduce(0, +), notes.count) // 버려지는 음이 없어야 한다

        var index = 0
        for count in breaks {
            let beats = notes[index..<(index + count)].reduce(0.0) { $0 + $1.beats }
            XCTAssertLessThanOrEqual(beats, 4.0, "마디 하나에 \(beats)박이 들어갔다")
            index += count
        }
    }
}
