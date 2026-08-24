import Foundation

/// 악보가 붙었을 때의 한 걸음 — 조옮김 추정 → 정렬·교정 → 조성 결정을 묶는다 (155절).
///
/// 파이프라인(`RecordingAnalyzer`)에서 떼어 순수 함수로 둔 이유는 오디오 없이 테스트하기
/// 위해서다(CLAUDE.md: 조합 로직을 View나 글루 코드 안에 두지 말 것).
///
/// **포기할 줄 아는 것이 이 타입의 핵심이다.** 다른 노래를 불렀거나 악보를 잘못 올렸을 때
/// 억지로 맞추면 멀쩡한 채보를 악보 쪽으로 끌고 가 더 망가뜨린다.
enum ScoreGuidedCorrection {

    struct Comparison: Equatable {
        /// 악보를 몇 반음 옮겨 불렀는지(추정). 포기했으면 참고값일 뿐이다.
        let transposition: Int
        let confidence: Double
        /// 교정을 실제로 적용했는지. false면 결과는 부른 그대로다.
        let isApplied: Bool
        let matchedCount: Int
        let missedCount: Int
        let extraCount: Int
        let snappedCount: Int
        /// 비교 화면이 "부른 대로 / 교정 후"를 나란히 보여주려면 원본이 남아 있어야 한다.
        let notesBeforeCorrection: [MelodySegmenter.SegmentedNote]

        static func notApplied(transposition: Int = 0, confidence: Double = 0,
                               sung: [MelodySegmenter.SegmentedNote]) -> Comparison {
            Comparison(transposition: transposition, confidence: confidence, isApplied: false,
                       matchedCount: 0, missedCount: 0, extraCount: 0, snappedCount: 0,
                       notesBeforeCorrection: sung)
        }
    }

    struct Outcome {
        let notes: [MelodySegmenter.SegmentedNote]
        /// 악보 조표에서 온 조성. 조표가 없거나 교정을 포기했으면 nil — 호출부가 기존
        /// 조성 판별(`KeyDetector`)로 간다.
        let key: KeyDetector.DetectedKey?
        let comparison: Comparison
    }

    /// 짝지어진 음이 이 비율 미만이면 교정을 포기한다.
    ///
    /// 조옮김 신뢰도만으로는 부족하다 — 음이름 분포가 우연히 닮았어도 순서가 전혀 다르면
    /// 정렬에서 대부분 누락·추가로 떨어진다. **실제로 맞춰본 결과**가 마지막 관문이다.
    /// 절반은 첫 값이고 실기기 로그로 조정한다.
    static let minimumMatchRatio = 0.5

    static func apply(sung: [MelodySegmenter.SegmentedNote],
                      reference: ScoreImporter.ImportedScore) -> Outcome {
        guard !sung.isEmpty, !reference.notes.isEmpty else {
            return Outcome(notes: sung, key: nil, comparison: .notApplied(sung: sung))
        }

        let sungProfile = sung.map { PitchedNote(midiNote: $0.midiNote, duration: $0.duration) }
        guard let estimate = TranspositionEstimator.estimate(sung: sungProfile, reference: reference.notes),
              estimate.confidence >= TranspositionEstimator.minimumConfidence else {
            return Outcome(notes: sung, key: nil, comparison: .notApplied(sung: sung))
        }

        // 조옮김을 반영한 악보 음으로 맞춘다 — 악보의 절대 음높이로 끌어내리면 부른 노래가
        // 통째로 딴 키가 된다.
        let transposed = reference.notes.map { $0.midiNote + estimate.semitones }
        let corrected = MelodyScoreCorrector.correct(sung: sung, reference: transposed)

        let comparable = Double(min(sung.count, transposed.count))
        guard comparable > 0, Double(corrected.matchedCount) / comparable >= minimumMatchRatio else {
            return Outcome(notes: sung, key: nil,
                           comparison: .notApplied(transposition: estimate.semitones,
                                                   confidence: estimate.confidence, sung: sung))
        }

        return Outcome(
            notes: corrected.notes,
            key: transposedKey(reference.key, by: estimate.semitones),
            comparison: Comparison(
                transposition: estimate.semitones,
                confidence: estimate.confidence,
                isApplied: true,
                matchedCount: corrected.matchedCount,
                missedCount: corrected.missedCount,
                extraCount: corrected.extraCount,
                snappedCount: corrected.snappedCount,
                notesBeforeCorrection: sung
            )
        )
    }

    /// 악보 조표를 부른 키로 옮긴다. 152절의 "조성이 반음 위로 뒤집힘"은 낮은 진폭에서
    /// pitch-class 분포가 번져 생긴 문제였는데, 조표가 있으면 그 추정 자체를 건너뛴다.
    private static func transposedKey(_ key: KeyDetector.DetectedKey?, by semitones: Int) -> KeyDetector.DetectedKey? {
        guard let key else { return nil }
        let tonic = ((key.tonicPitchClass + semitones) % 12 + 12) % 12
        return KeyDetector.DetectedKey(tonicPitchClass: tonic, mode: key.mode, confidence: key.confidence)
    }
}
