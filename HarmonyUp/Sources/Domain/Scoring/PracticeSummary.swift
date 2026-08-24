import Foundation

/// 채점 시도 하나(3도 또는 5도를 한동안 따라 부른 것) 동안 쌓인 PitchScorer.Score들을
/// 하나의 요약 통계로 압축한다. 프레임(46ms)마다 나오는 원시 점수를 그대로 다 저장하면
/// 너무 많고 의미도 없어서, "이번 시도는 대체로 얼마나 정확했나"로 요약해서 저장한다.
enum PracticeSummary {

    struct Aggregate {
        let sampleCount: Int
        let onPitchRatio: Double          // 0~1, 허용오차 이내였던 프레임의 비율
        let averageAbsCentsOffset: Double  // 부호를 무시한(높든 낮든) 평균 편차 — "얼마나 벗어났나"의 크기
    }

    static func aggregate(scores: [PitchScorer.Score]) -> Aggregate? {
        guard !scores.isEmpty else { return nil }

        let onPitchCount = scores.filter(\.isOnPitch).count
        let totalAbsCents = scores.reduce(0.0) { $0 + abs($1.centsOffset) }

        return Aggregate(
            sampleCount: scores.count,
            onPitchRatio: Double(onPitchCount) / Double(scores.count),
            averageAbsCentsOffset: totalAbsCents / Double(scores.count)
        )
    }
}
