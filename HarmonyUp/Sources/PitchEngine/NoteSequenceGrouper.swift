import Foundation

/// 연속된 음이 같으면 하나로 묶어서 매번 다시 어택하지 않고 쭉 지속되는 구간으로 만든다.
/// 실제 아카펠라 편곡에서 베이스가 멜로디 리듬을 그대로 복사하지 않고 지속음+독립적인 리듬을
/// 섞어 쓰는 것과 같은 원리다(docs/CONCEPTS.md 50절) — 지금 화음 라인 재생은 멜로디 스텝마다
/// 무조건 새로 어택해서, 멜로디가 같은 음을 반복해도 화음 성부가 매번 끊어져 재시작하는 것처럼
/// 들려 "뻣뻣하다"는 피드백의 한 원인이었다.
enum NoteSequenceGrouper {
    struct HeldNote {
        let frequency: Double
        /// 이 지속음이 원래 멜로디 스텝 몇 개를 대신하는지 — 재생 시 이 배수만큼 길게 유지한다.
        let holdCount: Int
    }

    /// 부동소수점 주파수를 직접 비교하면 계산 과정의 반올림 오차로 "같은 음인데 다르다"고
    /// 오판할 수 있어서, 몇 cent 이내면 같은 음으로 취급한다(사람 귀가 구분 못 하는 수준).
    private static let sameNoteToleranceCents = 5.0

    static func group(_ frequencies: [Double]) -> [HeldNote] {
        var result: [HeldNote] = []
        for frequency in frequencies {
            if let last = result.last, isSameNote(last.frequency, frequency) {
                result[result.count - 1] = HeldNote(frequency: last.frequency, holdCount: last.holdCount + 1)
            } else {
                result.append(HeldNote(frequency: frequency, holdCount: 1))
            }
        }
        return result
    }

    private static func isSameNote(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return a == b }
        let cents = abs(1200.0 * log2(b / a))
        return cents < sameNoteToleranceCents
    }
}
