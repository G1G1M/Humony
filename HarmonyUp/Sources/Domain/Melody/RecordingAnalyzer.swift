import Foundation

/// 녹음 전체를 한 번에 분석하는 배치 파이프라인의 "글루" 코드 — `MelodySegmenter`가 잘라낸
/// 음표들을 이미 순수 함수인 `KeyDetector`/`ChordGenerator`에 그대로 넘기고, 그 결과를 기존
/// 실시간 캡처 UI가 쓰던 `MelodyStep` 배열로 변환한다. `MelodySession`의 배치 버전 격이지만,
/// `MelodySession`은 프레임을 하나씩 받는 API라 "이미 다 끝난 분석 결과를 통째로 로드"하는
/// 이 용도엔 안 맞아서 대체하지 않고 별도로 둔다.
enum RecordingAnalyzer {

    struct AnalyzedRecording {
        let notes: [MelodySegmenter.SegmentedNote]
        let key: KeyDetector.DetectedKey?
        // notes 배열의 인덱스 -> 그 음의 3성부(베이스/3도/5도) 화음. 온음계 밖 음(ChordGenerator가 nil을 주는 경우)은
        // 이 딕셔너리에 아예 항목이 없다 — "화음 없음"을 별도 케이스로 발명하지 않고 기존
        // ChordGenerator의 nil 의미를 그대로 물려받는다.
        let harmonies: [Int: [ChordGenerator.HarmonyNote]]
        let voiceSamples: [Float]
        let sampleRate: Double
        /// 악보를 붙여 분석했을 때의 대조 결과. 악보 없이 부르면 nil이다(155절).
        let scoreComparison: ScoreGuidedCorrection.Comparison?
    }

    /// - Parameter reference: 사용자가 붙인 악보(155절). **기본값 nil이면 기존 동작 그대로다** —
    ///   악보 없이 부르는 흐름이 이 변경으로 달라지면 안 된다.
    static func analyze(
        recordingSamples: [Float],
        sampleRate: Double,
        reference: ScoreImporter.ImportedScore? = nil,
        segmenterConfiguration: MelodySegmenter.Configuration = .default
    ) -> AnalyzedRecording {
        let segmented = MelodySegmenter.segment(samples: recordingSamples, sampleRate: sampleRate, configuration: segmenterConfiguration)

        // 악보가 있으면 음높이를 악보에 맞춰 교정하고 조성도 조표에서 가져온다. 맞지 않는
        // 악보면 교정을 포기하고(comparison.isApplied == false) 부른 그대로 내려간다.
        let correction = reference.map { ScoreGuidedCorrection.apply(sung: segmented, reference: $0) }
        let notes = correction?.notes ?? segmented

        // KeyDetector는 이미 "음 목록(pitch class + 길이)"을 배치로 받는 순수 함수라 그대로 재사용한다.
        let weightedNotes = notes.map { KeyDetector.WeightedNote(pitchClass: $0.midiNote.mod(12), duration: $0.duration) }
        let key = correction?.key ?? KeyDetector.detectKey(notes: weightedNotes)

        var harmonies: [Int: [ChordGenerator.HarmonyNote]] = [:]
        if let key {
            // ChordGenerator.harmonizeSequence는 Viterbi로 노트 시퀀스 전체의 문맥을 보고 코드
            // 진행을 고르므로, 노트별로 따로따로가 아니라 한 번에 통째로 넘겨야 한다.
            let sequence = ChordGenerator.harmonizeSequence(melodyNotes: notes.map { ($0.midiNote, $0.duration) }, key: key)
            for (index, harmony) in sequence.enumerated() {
                if let harmony {
                    harmonies[index] = harmony
                }
            }
        }

        return AnalyzedRecording(notes: notes, key: key, harmonies: harmonies,
                                 voiceSamples: recordingSamples, sampleRate: sampleRate,
                                 scoreComparison: correction?.comparison)
    }

    /// 기존 멜로디 모드 UI(조성+화음 카드, `MelodyStepRow`, 스텝별 채점)가 그대로 소비할 수 있는
    /// 형태로 변환한다 — 이게 되면 새 UI를 거의 안 만들어도 "녹음한 걸 바탕으로 연습하기"가 된다.
    static func melodySteps(from analyzed: AnalyzedRecording) -> [MelodyStep] {
        analyzed.notes.enumerated().map { index, note in
            let frequency = NoteNameConverter.frequency(forMIDINote: note.midiNote)
            let noteName = NoteNameConverter.convert(frequency: frequency)?.noteName ?? "?"
            return MelodyStep(
                noteName: noteName,
                midiNote: note.midiNote,
                harmonyVoices: MelodyStep.harmonyVoices(from: analyzed.harmonies[index]),
                harmony: analyzed.harmonies[index],
                onsetTime: note.onsetTime,
                duration: note.duration
            )
        }
    }
}
