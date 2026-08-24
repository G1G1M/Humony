import Foundation

/// 음이 시작한 시각들로부터 "1박이 몇 초인지"를 추정한다(순수 함수).
///
/// **왜 필요한가**: `RhythmQuantizer`는 지금 "전체 음 길이의 중앙값 = 1박"이라는 상대적
/// 기준만 쓴다. 그러면 8분음표가 지배적인 노래에서 그 8분음표가 4분음표로 표기되고, 실제
/// 리듬과 악보가 어긋난다("박자·음표 길이가 이상하다"는 제보의 한 갈래). 중앙값은 "가장 흔한
/// 길이"일 뿐 "박"이 아니다.
///
/// **어떻게**: 박 후보(초당 40~200회 범위)를 촘촘히 훑으면서, 실제 음 간격들이 그 후보의
/// 자연스러운 음표 비율(1박, 반박, 두 박, 점4분음표…)에 얼마나 잘 들어맞는지 점수를 매기고
/// 가장 높은 후보를 고른다. 자기상관이나 빗살 필터를 쓰는 정교한 방식도 있지만, 소절 하나에
/// 음이 수십 개뿐이라 이 정도 단순 탐색으로 충분하고 왜 그 답이 나왔는지 설명하기도 쉽다
/// (CLAUDE.md: 복잡한 해법보다 단순한 해법을 먼저).
enum TempoEstimator {

    /// 사람이 노래하는 템포 범위. **박 모호성의 실질적 타이브레이커**이기도 하다 — 0.5초
    /// 간격은 120BPM(간격 하나 = 1박)으로도, 240BPM(간격 하나 = 두 박)으로도 설명할 수 있는데
    /// 240은 이 범위를 벗어나므로 자연히 탈락한다.
    static let minimumBPM = 40.0
    static let maximumBPM = 200.0

    struct Estimate: Equatable {
        /// 1박의 길이(초).
        let beatDuration: Double
        /// 실제 간격들이 이 박에 얼마나 잘 맞았는지(0~1). 무반주로 자유롭게 부르면 낮게 나오고,
        /// 그때는 호출부가 기존 방식으로 폴백하는 게 낫다 — 박이 없는 노래를 억지로 격자에
        /// 맞추면 악보가 오히려 더 이상해진다.
        let confidence: Double

        var bpm: Double { 60.0 / beatDuration }

        /// 실제 길이(초)가 몇 박인지 — 음표 모양으로 스냅하는 건 `RhythmQuantizer`의 몫이라
        /// 여기서는 비율을 그대로 돌려준다.
        func beats(forDuration duration: Double) -> Double {
            duration / beatDuration
        }
    }

    /// 음 간격이 1박의 몇 배일 때 자연스러운지와, 그 해석에 줄 가중치.
    ///
    /// 가중치를 다르게 주는 이유는 **박 모호성** 때문이다 — 같은 간격들을 절반 박으로도 두 배
    /// 박으로도 설명할 수 있어서, 아무 선호가 없으면 점수가 동점이 된다. "간격 하나가 곧 1박"인
    /// 해석을 가장 선호하고(1.0), 반박·두 박은 그다음, 점4분음표는 조금 더 낮게 둔다.
    ///
    /// **이 목록은 `RhythmQuantizer`가 실제로 그릴 수 있는 음표와 일치해야 한다.** 처음엔
    /// 16분음표(0.25박)와 점2분·온음표(3·4박)까지 넣었는데, 그러면 자유 리듬(박이 없는 노래)의
    /// 아무 간격이나 "3박이네, 4박이네"로 설명되면서 확신이 부풀어 폴백이 작동하지 않았다 —
    /// 정작 `RhythmQuantizer.classify`는 8분~2분음표까지만 표기하므로, **그릴 수도 없는 해석으로
    /// 박을 정하고 있었던 셈**이다. 어휘를 맞추자 자유 리듬이 제대로 걸러졌다.
    private static let noteRatios: [(ratio: Double, weight: Double)] = [
        (1.0, 1.0),   // 4분음표
        (0.5, 0.9),   // 8분음표
        (2.0, 0.9),   // 2분음표
        (1.5, 0.8),   // 점4분음표
    ]

    /// 비율이 이 정도(15%)까지 어긋나도 그 음표로 인정한다 — 사람이 부르는 리듬은 기계처럼
    /// 정확하지 않고, 이보다 좁히면 실제 노래에서 박을 거의 못 찾는다.
    private static let ratioTolerance = 0.15

    /// 박 후보를 훑는 간격(초). 0.005초면 120BPM 근처에서 약 1BPM 해상도라 충분하고,
    /// 후보가 240개뿐이라 비용도 무시할 만하다.
    private static let searchStep = 0.005

    /// 이보다 짧은 간격은 음 사이 간격이 아니라 분석 잡음으로 본다(같은 음이 잘못 쪼개진 경우 등).
    private static let minimumInterval = 0.05

    /// - Parameter onsetTimes: 음이 시작한 시각(초), 순서대로. `MelodyStep.onsetTime`을 그대로 넘기면 된다.
    /// - Returns: 간격이 너무 적어 판단할 수 없으면 nil. 확신이 낮은 경우에도 값은 돌려주므로
    ///   호출부가 `confidence`를 보고 쓸지 말지 정한다.
    static func estimate(onsetTimes: [Double]) -> Estimate? {
        let intervals = zip(onsetTimes.dropFirst(), onsetTimes)
            .map { $0 - $1 }
            .filter { $0 >= minimumInterval }
        // 간격이 두어 개뿐이면 어떤 박에도 그럴듯하게 들어맞아서 추정이 의미가 없다.
        guard intervals.count >= 3 else { return nil }

        let shortestBeat = 60.0 / maximumBPM
        let longestBeat = 60.0 / minimumBPM

        var bestBeat = shortestBeat
        var bestScore = -1.0
        var candidate = shortestBeat
        while candidate <= longestBeat {
            let score = fitScore(intervals: intervals, beatDuration: candidate)
            if score > bestScore {
                bestScore = score
                bestBeat = candidate
            }
            candidate += searchStep
        }

        guard bestScore > 0 else { return nil }
        return Estimate(
            beatDuration: bestBeat,
            // 모든 간격이 정확히 1박이면 간격 개수만큼 점수가 쌓인다 — 그걸 1.0으로 정규화한다.
            confidence: min(1.0, bestScore / Double(intervals.count))
        )
    }

    /// 간격들이 이 박 후보에 얼마나 잘 맞는지. 간격마다 가장 잘 맞는 음표 해석 하나만 점수로 세고,
    /// 어느 음표로도 설명이 안 되는 간격은 0점이다.
    private static func fitScore(intervals: [Double], beatDuration: Double) -> Double {
        intervals.reduce(0.0) { total, interval in
            let ratio = interval / beatDuration
            let best = noteRatios.reduce(0.0) { best, note in
                let error = abs(ratio - note.ratio) / note.ratio
                guard error <= ratioTolerance else { return best }
                // 오차가 커질수록 점수가 떨어지되, 제곱으로 완만하게 — 선형으로 깎으면 사람이
                // 부르는 정도의 흔들림(수 %)에도 점수가 뚝 떨어져서 확신이 과소평가된다.
                let normalized = error / ratioTolerance
                return max(best, note.weight * (1 - normalized * normalized))
            }
            return total + best
        }
    }
}
