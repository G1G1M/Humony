import XCTest
@testable import Humony

/// "부른 대로 / 교정 후"를 두 줄로 나란히 그리는 페이로드 (158절).
///
/// **핵심 불변식: 두 줄의 음 개수가 같아야 한다.** 교정은 음을 버릴 수 있어서(악보에 없는 짧은
/// 떨림) 그냥 이어 붙이면 뒤가 밀려 엉뚱한 음끼리 위아래로 놓인다 — 정렬로 자리를 맞추고
/// 빈 자리는 쉼표로 채운다.
final class ScoreComparisonPayloadTests: XCTestCase {

    private func build(_ before: [Int], _ after: [Int]) -> VexFlowScorePayload.Payload {
        ScoreComparisonPayload.build(beforeMIDINotes: before, afterMIDINotes: after)
    }

    /// VexFlow는 샤프를 키 문자열이 아니라 **별도 플래그**로 들고 있다(`d#/4`가 아니라
    /// `d/4` + sharp) — 읽기 좋게 합쳐서 비교한다.
    private func keys(_ voice: VexFlowScorePayload.Payload.Voice) -> [String] {
        voice.notes.compactMap { note in
            note.key.map { key in
                note.sharp ? key.replacingOccurrences(of: "/", with: "#/") : key
            }
        }
    }

    func testDrawsTwoRowsInBeforeThenAfterOrder() {
        let payload = build([60, 62, 64], [60, 62, 64])

        XCTAssertEqual(payload.voices.count, 2)
        XCTAssertEqual(keys(payload.voices[0]), ["c/4", "d/4", "e/4"])
        XCTAssertEqual(keys(payload.voices[1]), ["c/4", "d/4", "e/4"])
    }

    /// 반음 흔들려 잘못 적힌 음이 악보 값으로 바뀐 자리 — 위아래가 다른 음으로 보여야
    /// "여기가 고쳐졌구나"를 눈으로 안다.
    func testShowsCorrectedPitchesOnTheSecondRow() {
        let payload = build([60, 63, 64], [60, 62, 64])

        XCTAssertEqual(keys(payload.voices[0]), ["c/4", "d#/4", "e/4"])
        XCTAssertEqual(keys(payload.voices[1]), ["c/4", "d/4", "e/4"])
    }

    /// **교정이 버린 음**(악보에 없는 짧은 떨림)은 아래 줄에서 쉼표가 된다 — 위 줄에는 남아
    /// 있어야 "이 음이 빠졌다"가 보인다.
    func testDroppedNoteBecomesARestOnTheCorrectedRow() {
        let payload = build([60, 61, 62], [60, 62])

        XCTAssertEqual(payload.voices[0].notes.count, payload.voices[1].notes.count)
        XCTAssertEqual(keys(payload.voices[0]), ["c/4", "c#/4", "d/4"])
        XCTAssertNil(payload.voices[1].notes[1].key, "버려진 자리는 쉼표여야 한다")
        XCTAssertEqual(keys(payload.voices[1]), ["c/4", "d/4"])
    }

    /// 마디선이 세로로 맞으려면 두 줄의 음 개수가 언제나 같아야 한다.
    func testBothRowsAlwaysHaveTheSameNoteCount() {
        for (before, after) in [([60, 61, 62, 63], [60, 62]), ([60], [60]), ([60, 72, 61], [60, 72])] {
            let payload = build(before, after)
            XCTAssertEqual(payload.voices[0].notes.count, payload.voices[1].notes.count,
                           "before=\(before) after=\(after)")
        }
    }

    /// 두 줄은 같은 음자리표를 써야 위아래를 그대로 견줄 수 있다.
    func testBothRowsShareTheSameClef() {
        let payload = build([45, 47, 48], [45, 47, 48])   // 낮은 음역

        XCTAssertEqual(payload.voices[0].clef, payload.voices[1].clef)
        XCTAssertEqual(payload.voices[0].clef, "bass")
    }

    func testEmptyInputProducesAnEmptyPayload() {
        XCTAssertEqual(ScoreComparisonPayload.build(beforeMIDINotes: [], afterMIDINotes: []),
                       VexFlowScorePayload.empty)
    }
}
