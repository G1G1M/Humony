import Foundation

/// Hz 주파수를 가장 가까운 평균율 노트명으로 변환한다.
enum NoteNameConverter {

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    // A4 = 440Hz, MIDI 노트 번호 69번을 기준으로 삼는 표준 튜닝 기준음.
    private static let referenceFrequency: Double = 440.0
    private static let referenceMIDINote: Double = 69.0

    struct Result {
        let noteName: String       // 예: "A4"
        let frequency: Double      // 입력 주파수(Hz)
        let centsOffset: Double    // 가장 가까운 평균율 음과의 편차(cent). 조율 정확도 검증에 사용.
        let pitchClass: Int        // 옥타브 무관 음이름(0=C, 1=C#, ... 11=B). 조성 판별(KeyDetector)에서 사용.
    }

    /// 반올림하지 않은 정확한 MIDI 노트 번호. ChordGenerator 등 다른 컴포넌트가
    /// Hz ↔ MIDI 변환이 필요할 때 이 공식을 다시 베끼지 않고 재사용한다.
    static func exactMIDINote(forFrequency frequency: Double) -> Double {
        referenceMIDINote + 12.0 * log2(frequency / referenceFrequency)
    }

    /// MIDI 노트 번호 -> 주파수(Hz). 위 공식의 역변환.
    static func frequency(forMIDINote midiNote: Int) -> Double {
        referenceFrequency * pow(2.0, (Double(midiNote) - referenceMIDINote) / 12.0)
    }

    /// - Parameter frequency: 검출된 기본 주파수(Hz). 0 이하면 nil을 반환한다.
    static func convert(frequency: Double) -> Result? {
        guard frequency > 0 else { return nil }

        let exact = exactMIDINote(forFrequency: frequency)
        let roundedMIDINote = exact.rounded()

        // 1 semitone = 100 cent. 반올림한 음과의 차이를 cent 단위로 환산.
        let centsOffset = (exact - roundedMIDINote) * 100.0

        let noteIndex = Int(roundedMIDINote).mod(12)
        let octave = Int(roundedMIDINote) / 12 - 1

        return Result(
            noteName: "\(noteNames[noteIndex])\(octave)",
            frequency: frequency,
            centsOffset: centsOffset,
            pitchClass: noteIndex
        )
    }
}

extension Int {
    /// Swift `%`는 음수에 대해 음수를 반환하므로, 항상 [0, m) 범위로 정규화하는 mod.
    func mod(_ m: Int) -> Int {
        let r = self % m
        return r < 0 ? r + m : r
    }
}
