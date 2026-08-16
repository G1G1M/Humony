import XCTest
@testable import HarmonyUp

final class MelodySegmenterTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func sineWave(midiNote: Int, sampleCount: Int) -> [Float] {
        let frequency = NoteNameConverter.frequency(forMIDINote: midiNote)
        return (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    private func silence(sampleCount: Int) -> [Float] {
        Array(repeating: 0, count: sampleCount)
    }

    /// 기준 음 주변에서 주파수가 오르내리는(비브라토) 사인파. 순간 주파수를 적분해서 위상을 쌓는
    /// 방식이라, 단순히 sin(base*t)에 진폭 변조를 곱하는 것과 달리 실제로 주파수 자체가 흔들린다.
    private func vibratoWave(midiNote: Int, centsAmplitude: Double, vibratoRateHz: Double, sampleCount: Int) -> [Float] {
        let baseFrequency = NoteNameConverter.frequency(forMIDINote: midiNote)
        var phase = 0.0
        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let centsOffset = centsAmplitude * sin(2.0 * Double.pi * vibratoRateHz * Double(i) / sampleRate)
            let instantaneousFrequency = baseFrequency * pow(2.0, centsOffset / 1200.0)
            phase += 2.0 * Double.pi * instantaneousFrequency / sampleRate
            samples.append(Float(sin(phase)))
        }
        return samples
    }

    func testSingleSustainedNote() {
        let samples = sineWave(midiNote: 69, sampleCount: 8192) // A4

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.midiNote, 69)
        XCTAssertGreaterThan(notes.first?.duration ?? 0, 0.1)
    }

    func testTwoAdjacentNotesWithNoGapSplitOnPitchChange() {
        // 무음 구간 없이 바로 이어붙인 두 음 — 피치 변화만으로 경계를 잡아내야 한다.
        let samples = sineWave(midiNote: 60, sampleCount: 8192) + sineWave(midiNote: 64, sampleCount: 8192)

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(notes.map(\.midiNote), [60, 64])
        // 두 번째 음의 시작 시각이 대략 첫 음 길이(8192샘플 ≈ 0.186초) 근처여야 한다.
        XCTAssertEqual(notes[1].onsetTime, 8192.0 / sampleRate, accuracy: 0.05)
    }

    func testNotesSeparatedBySilenceSplitOnVADBoundary() {
        let samples = sineWave(midiNote: 60, sampleCount: 8192)
            + silence(sampleCount: 4096)
            + sineWave(midiNote: 64, sampleCount: 8192)

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(notes.map(\.midiNote), [60, 64])
    }

    func testShortBlipBelowMinimumDurationIsDropped() {
        // 분석 윈도우(2048샘플 ≈ 0.046초)보다 뚜렷이 짧은 blip(약 0.02초)이 무음 사이에 끼어 있어도
        // 결과에 나타나면 안 된다 — 숨소리/잡음성 튐을 걸러내는 목적. blip이 윈도우보다 길면
        // 여러 윈도우에 걸쳐 "스며들어" 실제보다 길게 잡힐 수 있어서, 일부러 윈도우보다 짧게 잡았다.
        let blipSampleCount = Int(0.02 * sampleRate)
        let samples = silence(sampleCount: 4096)
            + sineWave(midiNote: 64, sampleCount: blipSampleCount)
            + silence(sampleCount: 4096)

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertFalse(notes.map(\.midiNote).contains(64))
    }

    func testVibratoCollapsesToOneNote() {
        // 기준음 주변 ±30cent로 흔들리는 비브라토 — 반음(100cent) 안쪽이라 반올림한 MIDI 노트
        // 자체는 안 바뀌어야 하고, 그러면 여러 음으로 쪼개지지 않고 한 음으로 이어져야 한다.
        let samples = vibratoWave(midiNote: 69, centsAmplitude: 30, vibratoRateHz: 5.5, sampleCount: 16384)

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.midiNote, 69)
    }

    func testEmptyBufferReturnsNoNotes() {
        XCTAssertTrue(MelodySegmenter.segment(samples: [], sampleRate: sampleRate).isEmpty)
    }

    func testBufferShorterThanWindowReturnsNoNotes() {
        let samples = sineWave(midiNote: 69, sampleCount: 512)
        XCTAssertTrue(MelodySegmenter.segment(samples: samples, sampleRate: sampleRate).isEmpty)
    }
}
