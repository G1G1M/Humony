import Foundation

/// 악보와 대조한 결과를 사람이 읽는 한 줄로 (155절).
///
/// PRODUCT.md 원칙5("소스코드를 모르는 첫 사용자도 화면만 보고 따라갈 수 있어야") — 숫자를
/// 그대로 던지지 않고 무슨 일이 있었는지를 말한다. UI 크리틱에서 원시 진폭값을 그대로 보여주던
/// 것을 지적받은 것과 같은 원칙이다.
///
/// 뷰가 아니라 여기 두는 이유: 문구 조립은 순수 계산이고 유닛테스트로 고정할 수 있다.
enum ScoreComparisonSummary {

    static func text(for comparison: ScoreGuidedCorrection.Comparison) -> String {
        // **포기했을 때가 가장 중요하다** — 사용자는 악보를 붙였으니 당연히 맞춰졌다고 생각한다.
        // 안 맞았다는 사실과, 그래도 결과는 나왔다는 사실을 같이 알려야 한다.
        guard comparison.isApplied else {
            return "악보와 잘 맞지 않아서 부른 대로 뽑았어요"
        }

        var parts = ["악보와 \(comparison.matchedCount)음 일치"]
        // 없는 문제를 말하지 않는다 — 0을 나열하면 문제가 있는 것처럼 읽힌다.
        if comparison.missedCount > 0 { parts.append("\(comparison.missedCount)음 누락") }
        if comparison.extraCount > 0 { parts.append("\(comparison.extraCount)음 더 부름") }

        var text = parts.joined(separator: " · ")
        if let shift = transpositionText(comparison.transposition) {
            text += "\n" + shift
        }
        return text
    }

    /// 자기가 무슨 키로 불렀는지 모르고 부르는 경우가 많아서 알려준다.
    /// 옥타브 차이는 "12반음"이 아니라 "한 옥타브"로 말한다 — 남성이 여성 음역 악보를 볼 때
    /// 흔한 상황이고, 반음 숫자로는 무슨 말인지 알기 어렵다.
    private static func transpositionText(_ semitones: Int) -> String? {
        guard semitones != 0 else { return nil }

        let direction = semitones > 0 ? "높게" : "낮게"
        let distance = abs(semitones)

        if distance.isMultiple(of: 12) {
            let octaves = distance / 12
            return "악보보다 \(octaves == 1 ? "한" : "\(octaves)") 옥타브 \(direction) 부르셨어요"
        }
        return "악보보다 \(distance)반음 \(direction) 부르셨어요"
    }
}
