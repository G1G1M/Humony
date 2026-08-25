import Foundation

/// 악보를 몇 반음 옮겨 불렀는지 추정한다 (155절).
///
/// **왜 필요한가**: 음역 때문에 편한 키로 옮겨 부르는 건 흔하다 — 악보가 C장조인데 G장조로
/// 부르면 모든 음이 7반음 밀린다. 절대 음높이로 그냥 맞추면 전부 어긋나므로, 정렬·교정
/// **전에** 조옮김 양부터 정해야 한다.
///
/// **신뢰도가 이 타입의 절반이다.** 다른 노래를 불렀거나 악보를 잘못 올렸을 때 억지로 맞추면
/// 멀쩡한 채보를 악보 쪽으로 끌고 가 더 망가뜨린다 — 149절에 A#3 하나를 고치려다 음표 경계까지
/// 바뀌어 소리 회귀가 났던 것과 같은 종류의 위험이다. 확신이 없으면 호출부가 **교정을 포기하고**
/// 기존 파이프라인 그대로 가야 한다.
enum TranspositionEstimator {

    struct Estimate: Equatable {
        /// 부른 음 = 악보 음 + `semitones`. 옥타브까지 포함한 값이다.
        let semitones: Int
        /// 0(모호함)~1(확실함). 1위 회전과 2위 회전의 상관계수 차이 기반.
        let confidence: Double
    }

    /// 이 값 미만이면 호출부는 교정을 포기한다.
    ///
    /// 첫 값이다 — 실기기 로그로 조정한다. `KeyDetector`의 신뢰도와 같은 척도(1·2위 상관 차이를
    /// 0.3으로 나눠 0~1로 자름)를 쓰므로, 0.35는 "1·2위가 0.1 이상 벌어졌다" 정도에 해당한다.
    static let minimumConfidence = 0.35

    static func estimate(sung: [PitchedNote], reference: [PitchedNote]) -> Estimate? {
        guard !sung.isEmpty, !reference.isEmpty else { return nil }

        let sungProfile = PitchClassProfile.weighted(sung)
        let referenceProfile = PitchClassProfile.weighted(reference)

        // 실제로 부른 음높이가 악보보다 얼마나 위/아래인지. 평균이 아니라 중앙값인 이유는
        // 떨림 오탐이나 옥타브 오검출(YIN이 가끔 낸다) 한두 개가 결과를 통째로 옮기지 않게
        // 하기 위해서다.
        let pitchGap = median(sung.map(\.midiNote)) - median(reference.map(\.midiNote))

        // 12가지 회전 중 부른 분포와 가장 닮은 것을 찾는다. 회전 r은 "악보를 r반음 올려 불렀다"는 뜻.
        let candidates = (0..<12).map { rotation -> (rotation: Int, score: Double) in
            let correlation = PitchClassProfile.pearsonCorrelation(
                sungProfile, PitchClassProfile.rotate(referenceProfile, by: rotation))
            return (rotation, correlation - pitchProximityWeight * abs(signedDistance(rotation, from: pitchGap)))
        }.sorted { $0.score > $1.score }

        guard let best = candidates.first else { return nil }
        let runnerUp = candidates.count > 1 ? candidates[1].score : -1.0
        let confidence = min(max((best.score - runnerUp) / 0.3, 0), 1)

        return Estimate(
            semitones: withOctave(rotation: best.rotation, pitchGap: pitchGap),
            confidence: confidence
        )
    }

    /// 음이름 분포만으로는 갈리지 않는 경우가 있다 — 곡의 일부만 부르면 그 음들이 여러 조성에
    /// 동시에 들어가기 때문이다(예: D E F# G A는 D장조에도 G장조에도 전부 들어간다).
    /// 그때 판단을 갈라주는 건 **실제로 부른 음높이**다: 악보와 같은 높이로 불렀다면 7반음
    /// 아래(=5반음 위)로 옮겨 불렀다고 보는 것보다 2반음 위로 봤다고 보는 쪽이 맞다.
    ///
    /// 반음당 감점이라 뚜렷한 1위가 있을 때는 결과를 못 뒤집고, 후보가 붙어 있을 때만 갈린다
    /// (148절 `finalNoteTonicBonus`와 같은 성격의 아주 작은 단서다). 첫 값이라 실기기 로그로 조정한다.
    private static let pitchProximityWeight = 0.02

    /// `rotation`(0~11)과 실제 음높이 차이가 몇 반음 떨어졌는지 — 12로 감싸서 -6~6으로 잰다.
    /// 11과 0은 11반음이 아니라 1반음 차이다.
    private static func signedDistance(_ rotation: Int, from pitchGap: Double) -> Double {
        let raw = (Double(rotation) - pitchGap).truncatingRemainder(dividingBy: 12)
        if raw > 6 { return raw - 12 }
        if raw < -6 { return raw + 12 }
        return raw
    }

    /// 음이름 회전만으로는 옥타브를 모른다 — 7반음 위와 5반음 아래가 같은 회전으로 보인다.
    /// 회전이 알려주는 나머지를 유지한 채, 실제 음높이 차이에 가장 가까운 옥타브를 고른다.
    private static func withOctave(rotation: Int, pitchGap: Double) -> Int {
        let octaves = ((pitchGap - Double(rotation)) / 12).rounded()
        return rotation + Int(octaves) * 12
    }

    private static func median(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Double(sorted[middle - 1] + sorted[middle]) / 2
        }
        return Double(sorted[middle])
    }
}
