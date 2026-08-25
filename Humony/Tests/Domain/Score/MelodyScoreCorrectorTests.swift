import XCTest
@testable import Humony

/// 부른 음을 악보에 맞춰 교정한다 (155절).
///
/// **음높이만 고치고 타이밍은 부른 그대로 둔다** — 악보의 박자가 아니라 실제로 부른 리듬이
/// 화음 타이밍의 기준이기 때문이다. 무반주로 부르는 앱이라 템포를 강제할 수 없다.
final class MelodyScoreCorrectorTests: XCTestCase {

    private func sung(_ midiNote: Int, onset: Double, duration: Double) -> MelodySegmenter.SegmentedNote {
        MelodySegmenter.SegmentedNote(
            midiNote: midiNote, onsetTime: onset, duration: duration, averageConfidence: 0.9
        )
    }

    // MARK: - 스냅

    /// 짝지어진 음은 음높이를 악보 값으로 옮기고 **온셋·길이는 손대지 않는다.**
    func testSnapsPitchToTheScoreWhileKeepingTiming() {
        let result = MelodyScoreCorrector.correct(
            sung: [sung(60, onset: 0.0, duration: 0.5), sung(63, onset: 0.7, duration: 0.4)],
            reference: [60, 62]
        )

        XCTAssertEqual(result.notes.map(\.midiNote), [60, 62])
        XCTAssertEqual(result.notes.map(\.onsetTime), [0.0, 0.7])
        XCTAssertEqual(result.notes.map(\.duration), [0.5, 0.4])
        XCTAssertEqual(result.snappedCount, 1)
    }

    /// **스냅 한도**를 넘는 차이는 건드리지 않는다. 정렬이 잘못 짝지었을 때 엉뚱한 음으로
    /// 끌려가는 걸 막는 안전장치다 — 149절에 A#3 하나를 고치려다 음표 경계까지 바뀌어 소리
    /// 회귀가 났던 것과 같은 종류의 위험이다.
    func testDoesNotSnapWhenTheDifferenceExceedsTheLimit() {
        let result = MelodyScoreCorrector.correct(
            sung: [sung(65, onset: 0.0, duration: 0.5)],
            reference: [60],
            maximumSnapSemitones: 2
        )

        XCTAssertEqual(result.notes.map(\.midiNote), [65])
        XCTAssertEqual(result.snappedCount, 0)
    }

    /// 149절 실측 상황: G장조 곡인데 반음 경계에서 흔들린 구간이 A#3로 적혀 악보에 조성 밖 음이
    /// 남았다. 악보가 A3라고 말해주면 한 반음이므로 그대로 스냅된다.
    func testFixesTheSemitoneStrayThatLeftAnOutOfKeyNoteOnTheScore() {
        let result = MelodyScoreCorrector.correct(
            sung: [
                sung(55, onset: 0.0, duration: 0.4),    // G3
                sung(58, onset: 0.5, duration: 0.4),    // A#3 ← 오탐
                sung(59, onset: 1.0, duration: 0.4)     // B3
            ],
            reference: [55, 57, 59]                      // G3 A3 B3
        )

        XCTAssertEqual(result.notes.map(\.midiNote), [55, 57, 59])
    }

    // MARK: - 추가로 부른 음

    /// 악보에 없는데 부른 **짧은** 음은 떨림·군더더기로 보고 버린다. 153절이 소리 쪽에서
    /// 막아내던 것을 채보 단계에서 아예 없앤다.
    func testDropsShortNotesThatAreNotInTheScore() {
        let result = MelodyScoreCorrector.correct(
            sung: [
                sung(60, onset: 0.0, duration: 0.5),
                sung(61, onset: 0.55, duration: 0.08),   // 떨림
                sung(62, onset: 0.7, duration: 0.5)
            ],
            reference: [60, 62]
        )

        XCTAssertEqual(result.notes.map(\.midiNote), [60, 62])
        XCTAssertEqual(result.extraCount, 1)
    }

    /// 악보에 없어도 **길게** 부른 음은 남긴다 — 즉흥으로 넣었거나 악보가 그 부분을 안 담고
    /// 있을 수 있다. 부른 것을 지우는 건 짧아서 잡음이 확실할 때만이다.
    func testKeepsLongNotesThatAreNotInTheScore() {
        let result = MelodyScoreCorrector.correct(
            sung: [
                sung(60, onset: 0.0, duration: 0.5),
                sung(67, onset: 0.6, duration: 1.2),     // 길게 부른 음
                sung(62, onset: 1.9, duration: 0.5)
            ],
            reference: [60, 62]
        )

        XCTAssertEqual(result.notes.map(\.midiNote), [60, 67, 62])
    }

    // MARK: - 누락

    /// 악보에만 있는 음은 **만들어내지 않는다.** 안 부른 걸 악보에 그리면 거짓말이 되고,
    /// 그 자리에 화음까지 붙으면 부르지 않은 소리가 들린다.
    func testNeverInventsNotesThatWereNotSung() {
        let result = MelodyScoreCorrector.correct(
            sung: [sung(60, onset: 0.0, duration: 0.5), sung(64, onset: 1.0, duration: 0.5)],
            reference: [60, 62, 64]
        )

        XCTAssertEqual(result.notes.map(\.midiNote), [60, 64])
        XCTAssertEqual(result.missedCount, 1)
    }

    // MARK: - 안전한 기본값

    /// 악보가 비면 부른 그대로 — 악보 없는 흐름이 막히면 안 된다.
    func testReturnsTheSungNotesUnchangedWhenThereIsNoReference() {
        let notes = [sung(60, onset: 0.0, duration: 0.5), sung(61, onset: 0.6, duration: 0.05)]

        let result = MelodyScoreCorrector.correct(sung: notes, reference: [])

        XCTAssertEqual(result.notes, notes)
        XCTAssertEqual(result.snappedCount, 0)
    }

    /// 온셋 순서는 어떤 경우에도 유지돼야 한다 — 뒤 단계(화음 트랙 조립, 악보 타임라인)가
    /// 전부 시간순 배열을 전제한다.
    func testOutputStaysInOnsetOrder() {
        let result = MelodyScoreCorrector.correct(
            sung: [
                sung(60, onset: 0.0, duration: 0.4),
                sung(71, onset: 0.5, duration: 0.9),
                sung(62, onset: 1.5, duration: 0.4),
                sung(64, onset: 2.0, duration: 0.4)
            ],
            reference: [60, 62, 64]
        )

        let onsets = result.notes.map(\.onsetTime)
        XCTAssertEqual(onsets, onsets.sorted())
    }
}
