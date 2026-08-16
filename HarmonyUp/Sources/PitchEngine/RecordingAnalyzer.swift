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
        // notes 배열의 인덱스 -> 그 음의 3도/5도 화음. 온음계 밖 음(ChordGenerator가 nil을 주는 경우)은
        // 이 딕셔너리에 아예 항목이 없다 — "화음 없음"을 별도 케이스로 발명하지 않고 기존
        // ChordGenerator의 nil 의미를 그대로 물려받는다.
        let harmonies: [Int: [ChordGenerator.HarmonyNote]]
        let voiceSamples: [Float]
        let sampleRate: Double
    }

    static func analyze(
        recordingSamples: [Float],
        sampleRate: Double,
        segmenterConfiguration: MelodySegmenter.Configuration = .default
    ) -> AnalyzedRecording {
        let notes = MelodySegmenter.segment(samples: recordingSamples, sampleRate: sampleRate, configuration: segmenterConfiguration)

        // KeyDetector는 이미 "음 목록(pitch class + 길이)"을 배치로 받는 순수 함수라 그대로 재사용한다.
        let weightedNotes = notes.map { KeyDetector.WeightedNote(pitchClass: $0.midiNote.mod(12), duration: $0.duration) }
        let key = KeyDetector.detectKey(notes: weightedNotes)

        var harmonies: [Int: [ChordGenerator.HarmonyNote]] = [:]
        if let key {
            for (index, note) in notes.enumerated() {
                let frequency = NoteNameConverter.frequency(forMIDINote: note.midiNote)
                if let harmony = ChordGenerator.generateHarmony(melodyFrequency: frequency, key: key) {
                    harmonies[index] = harmony
                }
            }
        }

        return AnalyzedRecording(notes: notes, key: key, harmonies: harmonies, voiceSamples: recordingSamples, sampleRate: sampleRate)
    }

    /// 기존 멜로디 모드 UI(조성+화음 카드, `MelodyStepRow`, 스텝별 채점)가 그대로 소비할 수 있는
    /// 형태로 변환한다 — 이게 되면 새 UI를 거의 안 만들어도 "녹음한 걸 바탕으로 연습하기"가 된다.
    static func melodySteps(from analyzed: AnalyzedRecording) -> [MelodyStep] {
        analyzed.notes.enumerated().map { index, note in
            let frequency = NoteNameConverter.frequency(forMIDINote: note.midiNote)
            let noteName = NoteNameConverter.convert(frequency: frequency)?.noteName ?? "?"
            let harmonyNames = analyzed.harmonies[index].map { harmony in
                harmony
                    .map { NoteNameConverter.convert(frequency: $0.frequency)?.noteName ?? "?" }
                    .joined(separator: ", ")
            }
            return MelodyStep(
                noteName: noteName,
                midiNote: note.midiNote,
                harmonyNames: harmonyNames,
                onsetTime: note.onsetTime,
                duration: note.duration
            )
        }
    }
}
