import Foundation

/// 판별된 조성(KeyDetector.DetectedKey)을 기준으로, 멜로디 음의 diatonic(온음계) 3도/5도 화음을 생성한다.
enum ChordGenerator {

    enum Interval: Equatable {
        case third
        case fifth

        // 온음계에서 "3도 위", "5도 위"는 반음 몇 개가 아니라 음계상 몇 칸(scale degree) 위인지로 정의한다 —
        // 그래야 장3도/단3도가 조성에 따라 자동으로 올바르게 섞여 나온다(예: C장조의 3도는 C-E, D장조의 3도는 D-F#).
        var scaleDegreeStep: Int {
            switch self {
            case .third: return 2
            case .fifth: return 4
            }
        }
    }

    struct HarmonyNote {
        let interval: Interval
        let midiNote: Int
        let frequency: Double
        let pitchClass: Int
    }

    // 온음계를 이루는 반음 간격. 장조(Ionian)와 자연 단조(Aeolian) — 두 경우 모두
    // 으뜸음에서부터 7개 음이 어떤 반음 간격으로 놓이는지를 나타낸다.
    private static let majorScaleIntervals = [0, 2, 4, 5, 7, 9, 11]
    private static let minorScaleIntervals = [0, 2, 3, 5, 7, 8, 10]

    /// - Parameters:
    ///   - melodyFrequency: 사용자가 부른 멜로디 음(Hz)
    ///   - key: KeyDetector가 판별한 조성
    /// - Returns: [3도 위 화음, 5도 위 화음]. 멜로디 음이 판별된 조성의 온음계에 속하지 않으면
    ///   (예: 반음계 경과음) 온음계 화성을 정의할 수 없으므로 nil을 반환한다.
    static func generateHarmony(melodyFrequency: Double, key: KeyDetector.DetectedKey) -> [HarmonyNote]? {
        guard melodyFrequency > 0 else { return nil }

        let melodyMIDINote = Int(NoteNameConverter.exactMIDINote(forFrequency: melodyFrequency).rounded())
        let melodyPitchClass = melodyMIDINote.mod(12)

        let scale = diatonicScale(tonic: key.tonicPitchClass, mode: key.mode)
        guard let degree = scale.firstIndex(of: melodyPitchClass) else { return nil }

        return [
            harmonyNote(interval: .third, melodyDegree: degree, scale: scale, melodyMIDINote: melodyMIDINote),
            harmonyNote(interval: .fifth, melodyDegree: degree, scale: scale, melodyMIDINote: melodyMIDINote)
        ]
    }

    private static func diatonicScale(tonic: Int, mode: KeyDetector.Mode) -> [Int] {
        let intervals = mode == .major ? majorScaleIntervals : minorScaleIntervals
        return intervals.map { (tonic + $0).mod(12) }
    }

    private static func harmonyNote(
        interval: Interval,
        melodyDegree: Int,
        scale: [Int],
        melodyMIDINote: Int
    ) -> HarmonyNote {
        let targetDegree = (melodyDegree + interval.scaleDegreeStep) % 7
        let targetPitchClass = scale[targetDegree]

        // 멜로디 음과 같은 옥타브에서 목표 음이름의 위치를 찾은 뒤, 그게 멜로디 음보다 낮으면
        // 한 옥타브 올려서 항상 "멜로디 위로 쌓은 화음"이 되게 한다 (3도 위, 5도 위이므로).
        let melodyOctaveBase = melodyMIDINote - melodyMIDINote.mod(12)
        var targetMIDINote = melodyOctaveBase + targetPitchClass
        if targetMIDINote <= melodyMIDINote {
            targetMIDINote += 12
        }

        return HarmonyNote(
            interval: interval,
            midiNote: targetMIDINote,
            frequency: NoteNameConverter.frequency(forMIDINote: targetMIDINote),
            pitchClass: targetPitchClass
        )
    }
}
