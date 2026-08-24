import Foundation
import SwiftData

/// 녹음 한 번(= 멜로디를 불러 화음을 뽑아낸 한 세션)과, 그 안에서 성부별로 따라 부른 채점 시도들.
///
/// **136절, 세션 단위로 재설계**: 예전엔 `PracticeAttempt`(채점 시도)만 평평하게 쌓여서 기록 탭이
/// "3도 82%" 같은 줄의 나열이었다 — 어느 노래를 부르다 나온 점수인지, 같은 녹음에서 성부를 바꿔
/// 여러 번 시도한 것인지 구분할 수 없었다. 이제 녹음 하나가 세션이 되고 그 아래 성부별 시도가
/// 달린다("8월 24일 · C장조 · 음 12개 / 3도 82% · 5도 71%").
///
/// 그때 부른 멜로디와 화음을 MIDI 노트로 함께 저장해서, 기록에서 **그때의 악보를 다시 볼 수**
/// 있게 한다 — 오디오 파일은 저장하지 않는다(녹음 하나가 수 MB인데 악보를 다시 그리는 데는
/// 음높이와 길이만 있으면 충분하다).
@Model
final class PracticeSession {
    var date: Date

    /// 그때 판별된 조성 이름(`KeyDetector.DetectedKey.name`). 판별 실패 세션은 저장되지 않으므로
    /// 항상 값이 있지만, 스키마 유연성을 위해 문자열로 둔다.
    var keyName: String

    /// 그때 부른 멜로디 — 순서대로의 MIDI 노트와 각 음의 길이(초). 두 배열은 항상 같은 길이다.
    var melodyMIDINotes: [Int]
    var melodyDurations: [Double]

    /// 성부(`ChordGenerator.Interval.storageKey`) -> 그 성부의 MIDI 노트 시퀀스.
    /// 화음이 없던 스텝은 `PracticeSession.restMarker`로 표시한다 — 배열 길이를 멜로디와
    /// 똑같이 유지해야 악보를 복원할 때 스텝이 어긋나지 않는다.
    var harmonyMIDINotes: [String: [Int]]

    @Relationship(deleteRule: .cascade, inverse: \PracticeAttempt.session)
    var attempts: [PracticeAttempt] = []

    /// 화음이 없는 스텝을 나타내는 표식 — 실제 MIDI 노트 범위(0~127)와 겹치지 않는 값이라
    /// "값이 있음/없음"을 별도 배열 없이 한 배열 안에서 표현할 수 있다.
    static let restMarker = -1

    init(date: Date, keyName: String, melodyMIDINotes: [Int], melodyDurations: [Double], harmonyMIDINotes: [String: [Int]]) {
        self.date = date
        self.keyName = keyName
        self.melodyMIDINotes = melodyMIDINotes
        self.melodyDurations = melodyDurations
        self.harmonyMIDINotes = harmonyMIDINotes
    }

    var noteCount: Int { melodyMIDINotes.count }
}

extension PracticeSession {

    /// 저장할 형태로 변환한다 — `MelodyStep` 배열(화면이 쓰는 형태)에서 필요한 것만 뽑는다.
    static func snapshot(of steps: [MelodyStep], keyName: String, date: Date) -> PracticeSession {
        var harmonies: [String: [Int]] = [:]
        for interval in ChordGenerator.Interval.allCases {
            let notes = steps.map { step in
                step.harmony?.first { $0.interval == interval }?.midiNote ?? restMarker
            }
            // 그 성부가 한 스텝도 없으면(조성 판별 실패 등) 아예 키를 만들지 않는다.
            guard notes.contains(where: { $0 != restMarker }) else { continue }
            harmonies[interval.storageKey] = notes
        }

        return PracticeSession(
            date: date,
            keyName: keyName,
            melodyMIDINotes: steps.map(\.midiNote),
            melodyDurations: steps.map { $0.duration ?? 0.3 },
            harmonyMIDINotes: harmonies
        )
    }

    /// 저장된 세션을 다시 `MelodyStep` 배열로 되돌린다 — 기록 화면이 기존
    /// `VexFlowScoreView`/`VexFlowScorePayload`를 그대로 재사용해 그때의 악보를 그릴 수 있다.
    ///
    /// `onsetTime`은 저장하지 않고 길이를 누적해 되살린다 — 악보에 필요한 건 "몇 번째 음이
    /// 얼마나 길었나"뿐이고, 원본 녹음의 절대 시각은 다시 쓸 일이 없다(무음 간격은 사라지지만
    /// 악보 표기에는 영향이 없다 — `VexFlowScorePayload`가 duration만 본다).
    func melodySteps() -> [MelodyStep] {
        var onset = 0.0
        return melodyMIDINotes.enumerated().map { index, midiNote in
            let duration = index < melodyDurations.count ? melodyDurations[index] : 0.3
            let harmony = harmonyNotes(atStep: index)
            let step = MelodyStep(
                noteName: NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?",
                midiNote: midiNote,
                harmonyVoices: MelodyStep.harmonyVoices(from: harmony),
                harmony: harmony,
                onsetTime: onset,
                duration: duration
            )
            onset += duration
            return step
        }
    }

    private func harmonyNotes(atStep index: Int) -> [ChordGenerator.HarmonyNote]? {
        let notes: [ChordGenerator.HarmonyNote] = ChordGenerator.Interval.allCases.compactMap { interval in
            guard let sequence = harmonyMIDINotes[interval.storageKey],
                  index < sequence.count,
                  sequence[index] != Self.restMarker else { return nil }
            let midiNote = sequence[index]
            return ChordGenerator.HarmonyNote(
                interval: interval,
                midiNote: midiNote,
                frequency: NoteNameConverter.frequency(forMIDINote: midiNote),
                pitchClass: midiNote.mod(12)
            )
        }
        return notes.isEmpty ? nil : notes
    }
}
