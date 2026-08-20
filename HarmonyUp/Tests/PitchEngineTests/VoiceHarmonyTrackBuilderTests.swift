import XCTest
@testable import HarmonyUp

final class VoiceHarmonyTrackBuilderTests: XCTestCase {

    private let rate: Double = 44100.0

    private func sineWave(frequency: Double, sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / rate))
        }
    }

    private func step(midiNote: Int, onset: Double, duration: Double, harmony: [ChordGenerator.HarmonyNote]?) -> MelodyStep {
        MelodyStep(
            noteName: NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?",
            midiNote: midiNote,
            harmonyVoices: nil,
            harmony: harmony,
            onsetTime: onset,
            duration: duration
        )
    }

    private func harmonyNotes(bass: Int, third: Int, fifth: Int) -> [ChordGenerator.HarmonyNote] {
        [
            ChordGenerator.HarmonyNote(interval: .bass, midiNote: bass, frequency: NoteNameConverter.frequency(forMIDINote: bass), pitchClass: bass.mod(12)),
            ChordGenerator.HarmonyNote(interval: .third, midiNote: third, frequency: NoteNameConverter.frequency(forMIDINote: third), pitchClass: third.mod(12)),
            ChordGenerator.HarmonyNote(interval: .fifth, midiNote: fifth, frequency: NoteNameConverter.frequency(forMIDINote: fifth), pitchClass: fifth.mod(12)),
        ]
    }

    // 길이 보존 불변식 — SynthesizedHarmonyTrackBuilderTests와 같은 이유(107절 교훈)로 검증.
    func testBuildAlwaysMatchesBufferLength() {
        let steps = [
            step(midiNote: 60, onset: 0.1, duration: 0.3, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67)),
            step(midiNote: 62, onset: 0.5, duration: 0.2, harmony: harmonyNotes(bass: 50, third: 65, fifth: 69)),
        ]
        let bufferLength = Int(1.0 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)

        for voice: VoiceHarmonyTrackBuilder.Voice in [.melody, .harmony(.bass), .harmony(.third), .harmony(.fifth)] {
            let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: voice, rate: rate)
            XCTAssertEqual(track.count, bufferLength)
        }
    }

    // 멜로디 성부는 피치 시프트 없이(비율 1) 원본 목소리를 그대로 써야 한다.
    func testMelodyVoiceUsesSourceAudioUnshifted() throws {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: nil)]
        let bufferLength = Int(0.2 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength) // C4

        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .melody, rate: rate, fadeDuration: 0)
        let candidates = YINPitchDetector.detectPitch(samples: Array(track[1000..<5000]), sampleRate: rate)
        let detected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(detected.frequency, 261.63, accuracy: 5)
    }

    // 화음 성부는 실제로 목표 주파수로 옮겨진 소리여야 한다(YIN으로 되짚어 검증 — PitchShifterTests와 같은 방식).
    func testHarmonyVoiceShiftsSourceToTargetFrequency() throws {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.3, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67))]
        let bufferLength = Int(0.3 * rate)
        let source = sineWave(frequency: NoteNameConverter.frequency(forMIDINote: 60), sampleCount: bufferLength) // C4를 불렀다고 가정

        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .harmony(.fifth), rate: rate, fadeDuration: 0)
        let candidates = YINPitchDetector.detectPitch(samples: Array(track[4000..<8000]), sampleRate: rate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = NoteNameConverter.frequency(forMIDINote: 67) // G4(5도)
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    // 온음계 밖 음이라 화음이 nil인 스텝은 그 성부에서 무음이어야 한다.
    func testStepWithoutHarmonyProducesSilenceForThatVoice() {
        let steps = [step(midiNote: 61, onset: 0.0, duration: 0.1, harmony: nil)]
        let bufferLength = Int(0.1 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)

        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .harmony(.third), rate: rate)
        XCTAssertTrue(track.allSatisfy { $0 == 0 })
    }

    func testEmptyMelodyStepsProducesSilentBufferOfRequestedLength() {
        let track = VoiceHarmonyTrackBuilder.build(melodySteps: [], sourceBuffer: [], bufferLength: 500, voice: .melody, rate: rate)
        XCTAssertEqual(track, [Float](repeating: 0, count: 500))
    }

    // 무음 없이 이어지는 두 음도 크로스페이드 구간에서 무음까지 떨어지면 안 된다(121절과 같은 원칙).
    // 128절: 멜로디는 더 이상 크로스페이드 경로를 안 타므로(패스스루), 화음 성부로 검증한다.
    func testContiguousTransitionCrossfadesWithoutDippingToSilence() {
        let steps = [
            step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67)),
            step(midiNote: 64, onset: 0.2, duration: 0.2, harmony: harmonyNotes(bass: 52, third: 68, fifth: 71)),
        ]
        let bufferLength = Int(0.4 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)
        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .harmony(.third), rate: rate)

        let boundary = Int(0.2 * rate)
        let window = track[max(0, boundary - 50)..<min(bufferLength, boundary + 50)]
        XCTAssertTrue(window.contains { abs($0) > 0.2 })
    }

    // 128절 회귀 테스트 — MelodySegmenter가 "음"으로 인식 못한 구간(숨소리/자음/저신뢰도 전환)이
    // 예전엔 완전한 무음으로 재생됐다. 멜로디는 세그먼트 재구성을 안 거치므로, 스텝 사이 미커버
    // 구간에도 원본 오디오가 그대로 남아있어야 한다.
    func testMelodyVoicePreservesAudioInGapsBetweenRecognizedSteps() {
        let steps = [
            step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: nil),
            step(midiNote: 62, onset: 0.4, duration: 0.2, harmony: nil),
        ]
        let bufferLength = Int(0.6 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)
        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .melody, rate: rate)

        // 0.2~0.4초는 두 스텝 어느 쪽에도 안 걸리는 "미인식 구간" — 원본엔 계속 소리가 있었다.
        let gapStart = Int(0.25 * rate)
        let gapEnd = Int(0.35 * rate)
        XCTAssertTrue(track[gapStart..<gapEnd].contains { abs($0) > 0.2 })
    }

    // 128절 — 멜로디는 이제 세그먼트 재구성 없이 원본을 그대로 돌려주는 패스스루라는 계약을 명시.
    func testMelodyVoiceIsIdenticalToSourceBufferWhenLengthsMatch() {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: nil)]
        let bufferLength = Int(0.2 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)

        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .melody, rate: rate)
        XCTAssertEqual(track, source)
    }
}
