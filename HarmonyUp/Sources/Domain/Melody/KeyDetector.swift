import Foundation

/// pitch-class 히스토그램과 key profile의 상관관계로 조성을 판별한다 (Krumhansl-Schmuckler 계열 key-finding).
/// 참고: Temperley, "What's Key for Key? The Krumhansl-Schmuckler Key-Finding Algorithm Reconsidered" (1999) —
/// 원조 Krumhansl-Kessler(1982) 프로파일 대신, 실제 곡 데이터로 재보정된 이 개정판(=Kostka-Payne 프로파일)을 쓴다.
enum KeyDetector {

    enum Mode: Equatable {
        case major
        case minor
    }

    struct DetectedKey {
        let tonicPitchClass: Int   // 0=C, 1=C#, ... 11=B
        let mode: Mode
        let confidence: Double     // 0(모호함)~1(확실함). 1위와 2위 후보의 상관계수 차이 기반.

        var name: String {
            let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
            return "\(names[tonicPitchClass]) \(mode == .major ? "Major" : "Minor")"
        }
    }

    /// 조성 판별 입력 단위. 음정을 몇 번 냈는지(개수)가 아니라 얼마나 오래 냈는지(길이)로 가중치를 준다 —
    /// 짧게 스쳐 지나간 경과음(passing tone)이 조성 판단을 왜곡하지 않도록 하기 위함 (PRD 부록 B 근거).
    struct WeightedNote {
        let pitchClass: Int    // 0-11
        let duration: Double   // 초 단위(또는 상대적 길이 가중치)

        init(pitchClass: Int, duration: Double) {
            self.pitchClass = pitchClass
            self.duration = duration
        }
    }

    // Temperley(1999) 개정 key profile. 각 배열은 그 조성의 으뜸음(tonic)을 기준으로,
    // 온음계 각 음이 곡에서 실제로 얼마나 "중심적인" 역할을 하는지를 나타내는 경험적 가중치다
    // (예: 으뜸음과 딸림음이 가장 높고, 반음계 밖 음은 낮다).
    private static let majorProfile: [Double] = [5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0]
    private static let minorProfile: [Double] = [5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 1.5, 4.0]

    /// - Returns: 24개 조성(장조 12 + 단조 12) 후보 중 입력 pitch-class 분포와 가장 상관이 높은 조성.
    ///   입력이 비어 있으면 nil.
    static func detectKey(notes: [WeightedNote]) -> DetectedKey? {
        guard !notes.isEmpty else { return nil }

        var pitchClassProfile = [Double](repeating: 0, count: 12)
        for note in notes {
            pitchClassProfile[note.pitchClass] += note.duration
        }

        let candidates = (0..<12).flatMap { tonic -> [(tonic: Int, mode: Mode, correlation: Double)] in
            [
                (tonic, .major, pearsonCorrelation(pitchClassProfile, rotate(majorProfile, toTonic: tonic))),
                (tonic, .minor, pearsonCorrelation(pitchClassProfile, rotate(minorProfile, toTonic: tonic)))
            ]
        }.sorted { $0.correlation > $1.correlation }

        guard let best = candidates.first else { return nil }
        let runnerUp = candidates.count > 1 ? candidates[1].correlation : -1.0

        // 1위와 2위의 상관계수 차이(margin)가 클수록 "이 조성이 확실하다"는 뜻.
        // 0.3은 여러 후보를 눈으로 비교해본 경험적 스케일 — 실제 곡 데이터로 추후 보정 필요.
        let confidence = min(max((best.correlation - runnerUp) / 0.3, 0), 1)

        return DetectedKey(tonicPitchClass: best.tonic, mode: best.mode, confidence: confidence)
    }

    /// 진단용 — 상위 후보를 점수와 함께 돌려준다(148절).
    ///
    /// 신뢰도 숫자 하나만으로는 "왜 낮은지"를 알 수 없다. 나란한조(구성음이 같아 화음 품질에
    /// 영향이 거의 없음)와 이웃 조성(으뜸음이 달라 화음 중심이 어긋남)은 둘 다 낮은 신뢰도로
    /// 나오지만 심각도가 완전히 다르다 — 2위가 무엇인지 봐야 갈린다. 실제로 이 구분이
    /// 148절 수정의 출발점이었고, 그때는 로그를 손으로 재현해서 알아내야 했다.
    static func topCandidates(notes: [WeightedNote], count: Int = 3) -> [(name: String, score: Double)] {
        guard !notes.isEmpty else { return [] }

        var pitchClassProfile = [Double](repeating: 0, count: 12)
        for note in notes {
            pitchClassProfile[note.pitchClass] += note.duration
        }
        let scored = (0..<12).flatMap { tonic -> [(name: String, score: Double)] in
            [
                (DetectedKey(tonicPitchClass: tonic, mode: .major, confidence: 0).name,
                 pearsonCorrelation(pitchClassProfile, rotate(majorProfile, toTonic: tonic))),
                (DetectedKey(tonicPitchClass: tonic, mode: .minor, confidence: 0).name,
                 pearsonCorrelation(pitchClassProfile, rotate(minorProfile, toTonic: tonic)))
            ]
        }.sorted { $0.score > $1.score }

        return Array(scored.prefix(count))
    }

    /// key profile은 "C를 으뜸음으로 하는 조성" 기준으로 정의돼 있으므로,
    /// 다른 으뜸음의 조성을 만들려면 배열을 그만큼 회전시킨다.
    private static func rotate(_ profile: [Double], toTonic tonic: Int) -> [Double] {
        (0..<12).map { pitchClass in profile[((pitchClass - tonic) % 12 + 12) % 12] }
    }

    /// 두 12차원 벡터(입력 pitch-class 분포 vs key profile)가 얼마나 비슷한 모양인지를
    /// -1(반대)~0(무관)~1(똑같은 모양)로 나타내는 피어슨 상관계수.
    private static func pearsonCorrelation(_ a: [Double], _ b: [Double]) -> Double {
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
