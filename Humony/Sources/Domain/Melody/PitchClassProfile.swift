import Foundation

/// 12개 음이름(pitch class)에 길이를 누적한 분포와, 그 분포를 비교하는 도구 (155절에 분리).
///
/// 원래 `KeyDetector` 안에 private으로 있던 것을 꺼냈다 — `TranspositionEstimator`가
/// **똑같은 계산**을 필요로 하기 때문이다. 조성 판별은 "이 분포가 어느 key profile과 닮았나"고,
/// 조옮김 추정은 "이 분포가 악보의 분포를 몇 칸 돌린 것과 닮았나"다. 닮은 정도를 재는 방법
/// (피어슨 상관)과 돌리는 방법(회전)이 같다.
enum PitchClassProfile {

    /// 음정을 **몇 번** 냈는지가 아니라 **얼마나 오래** 냈는지로 가중치를 준다 — 짧게 스쳐
    /// 지나간 경과음이나 떨림 오탐이 판단을 왜곡하지 않도록(PRD 부록 B, 153절 실측).
    static func weighted(_ notes: [PitchedNote]) -> [Double] {
        var profile = [Double](repeating: 0, count: 12)
        for note in notes {
            profile[((note.midiNote % 12) + 12) % 12] += note.duration
        }
        return profile
    }

    /// 분포를 오른쪽으로 `steps`칸 돌린다 — 결과의 `i`번 칸은 원본의 `i - steps`번 칸이다.
    ///
    /// 조성 판별에서는 "C 기준 key profile을 그 조성의 으뜸음으로 옮기는" 데 쓰고,
    /// 조옮김 추정에서는 "악보 분포를 몇 반음 올려 부른 것으로 보는" 데 쓴다.
    static func rotate(_ profile: [Double], by steps: Int) -> [Double] {
        (0..<12).map { pitchClass in profile[((pitchClass - steps) % 12 + 12) % 12] }
    }

    /// 두 12차원 벡터가 얼마나 비슷한 모양인지를 -1(반대)~0(무관)~1(똑같은 모양)로.
    ///
    /// **크기가 아니라 모양을 본다** — 30초를 부르든 3분을 부르든 같은 곡이면 같은 답이 나와야 한다.
    static func pearsonCorrelation(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        let n = Double(a.count)
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n

        var numerator = 0.0
        var sumSquaredA = 0.0
        var sumSquaredB = 0.0
        for i in 0..<a.count {
            let deviationA = a[i] - meanA
            let deviationB = b[i] - meanB
            numerator += deviationA * deviationB
            sumSquaredA += deviationA * deviationA
            sumSquaredB += deviationB * deviationB
        }

        let denominator = (sumSquaredA * sumSquaredB).squareRoot()
        guard denominator != 0 else { return 0 }
        return numerator / denominator
    }
}
