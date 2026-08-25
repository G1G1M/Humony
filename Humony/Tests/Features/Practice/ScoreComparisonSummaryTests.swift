import XCTest
@testable import Humony

/// 악보와 대조한 결과를 사람이 읽는 한 줄로 (155절).
///
/// PRODUCT.md 원칙5("소스코드를 모르는 첫 사용자도 화면만 보고 따라갈 수 있어야") —
/// 숫자를 그대로 던지지 않고 무슨 일이 있었는지를 말한다.
final class ScoreComparisonSummaryTests: XCTestCase {

    private func comparison(applied: Bool = true, transposition: Int = 0, confidence: Double = 0.9,
                            matched: Int = 0, missed: Int = 0, extra: Int = 0,
                            snapped: Int = 0) -> ScoreGuidedCorrection.Comparison {
        ScoreGuidedCorrection.Comparison(
            transposition: transposition, confidence: confidence, isApplied: applied,
            matchedCount: matched, missedCount: missed, extraCount: extra, snappedCount: snapped,
            notesBeforeCorrection: []
        )
    }

    func testDescribesMatchesMissesAndExtras() {
        let text = ScoreComparisonSummary.text(for: comparison(matched: 29, missed: 2, extra: 1))

        XCTAssertTrue(text.contains("29"), text)
        XCTAssertTrue(text.contains("2"), text)
        XCTAssertTrue(text.contains("1"), text)
    }

    /// 누락도 추가도 없으면 굳이 0을 나열하지 않는다 — 없는 문제를 말하지 않는 게 낫다.
    func testOmitsZeroCounts() {
        let text = ScoreComparisonSummary.text(for: comparison(matched: 12))

        XCTAssertFalse(text.contains("누락"), text)
        XCTAssertFalse(text.contains("더 부른"), text)
    }

    /// 조옮김은 사용자가 알아야 할 사실이다 — 자기가 무슨 키로 불렀는지 모르고 부르는 경우가 많다.
    func testMentionsTranspositionWhenTheKeyWasShifted() {
        let up = ScoreComparisonSummary.text(for: comparison(transposition: 7, matched: 10))
        let down = ScoreComparisonSummary.text(for: comparison(transposition: -5, matched: 10))

        XCTAssertTrue(up.contains("7"), up)
        XCTAssertTrue(up.contains("높게"), up)
        XCTAssertTrue(down.contains("5"), down)
        XCTAssertTrue(down.contains("낮게"), down)
    }

    func testDoesNotMentionTranspositionWhenSungInTheSameKey() {
        let text = ScoreComparisonSummary.text(for: comparison(transposition: 0, matched: 10))

        XCTAssertFalse(text.contains("높게"), text)
        XCTAssertFalse(text.contains("낮게"), text)
    }

    /// 옥타브 차이는 "12반음"이 아니라 "한 옥타브"로 말한다 — 남성이 여성 음역 악보를 볼 때
    /// 흔한 상황이고, 반음 숫자로 들으면 무슨 말인지 알기 어렵다.
    func testDescribesOctaveShiftsInOctaves() {
        let text = ScoreComparisonSummary.text(for: comparison(transposition: -12, matched: 10))

        XCTAssertTrue(text.contains("옥타브"), text)
        XCTAssertFalse(text.contains("12반음"), text)
    }

    /// **교정을 포기했을 때가 가장 중요하다** — 사용자는 악보를 붙였으니 당연히 맞춰졌다고
    /// 생각한다. 안 맞았다는 사실과, 그래도 결과는 나왔다는 사실을 같이 알려야 한다.
    func testExplainsWhenTheScoreDidNotMatch() {
        let text = ScoreComparisonSummary.text(for: comparison(applied: false, confidence: 0.1))

        XCTAssertTrue(text.contains("부른 대로"), text)
    }
}
