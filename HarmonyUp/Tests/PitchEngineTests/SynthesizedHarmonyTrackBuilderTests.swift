import XCTest
@testable import HarmonyUp

final class SynthesizedHarmonyTrackBuilderTests: XCTestCase {

    private let rate: Double = 44100.0

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

    // 불변식(길이 보존): 결과는 항상 bufferLength와 정확히 같아야 한다 — 107절에서 이 불변식이
    // 없어서 "화음이 밀리는" 버그가 생겼던 전례가 있어, 이번엔 테스트로 먼저 보장한다.
    func testBuildAlwaysMatchesBufferLength() {
        let steps = [
            step(midiNote: 60, onset: 0.1, duration: 0.3, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67)),
            step(midiNote: 62, onset: 0.5, duration: 0.2, harmony: harmonyNotes(bass: 50, third: 65, fifth: 69)),
        ]
        let bufferLength = Int(1.0 * rate)

        for voice: SynthesizedHarmonyTrackBuilder.Voice in [.melody, .harmony(.bass), .harmony(.third), .harmony(.fifth)] {
            let track = SynthesizedHarmonyTrackBuilder.build(melodySteps: steps, bufferLength: bufferLength, voice: voice, rate: rate)
            XCTAssertEqual(track.count, bufferLength)
        }
    }

    func testGapsBetweenStepsAreSilent() {
        let steps = [step(midiNote: 60, onset: 0.5, duration: 0.2, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67))]
        let bufferLength = Int(1.0 * rate)
        let track = SynthesizedHarmonyTrackBuilder.build(melodySteps: steps, bufferLength: bufferLength, voice: .melody, rate: rate)

        // 첫 스텝 시작(0.5초) 이전은 전부 무음이어야 한다.
        let beforeOnset = Array(track[0..<Int(0.4 * rate)])
        XCTAssertTrue(beforeOnset.allSatisfy { $0 == 0 })
    }

    func testHarmonyVoiceUsesMatchingIntervalFrequency() {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.1, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67))]
        let sampleCount = Int(0.1 * rate)
        let fadeDuration = 0.005
        let track = SynthesizedHarmonyTrackBuilder.build(melodySteps: steps, bufferLength: sampleCount, voice: .harmony(.third), rate: rate, segmentFadeDuration: fadeDuration)
        let rawTone = ToneSynthesizer.synthesize(frequency: NoteNameConverter.frequency(forMIDINote: 64), sampleCount: sampleCount, sampleRate: rate)
        let expected = AudioGain.applyFadeInOut(rawTone, fadeSampleCount: Int(rate * fadeDuration))
        XCTAssertEqual(track, expected)
    }

    // 온음계 밖 음이라 화음이 nil인 스텝(harmony == nil)은 그 구간이 무음이어야 한다 —
    // ChordGenerator의 "화음 없음" 의미를 그대로 물려받는다(RecordingAnalyzer와 동일 원칙).
    func testStepWithoutHarmonyProducesSilenceForThatVoice() {
        let steps = [step(midiNote: 61, onset: 0.0, duration: 0.1, harmony: nil)]
        let sampleCount = Int(0.1 * rate)
        let track = SynthesizedHarmonyTrackBuilder.build(melodySteps: steps, bufferLength: sampleCount, voice: .harmony(.third), rate: rate)
        XCTAssertTrue(track.allSatisfy { $0 == 0 })
    }

    func testEmptyMelodyStepsProducesSilentBufferOfRequestedLength() {
        let track = SynthesizedHarmonyTrackBuilder.build(melodySteps: [], bufferLength: 500, voice: .melody, rate: rate)
        XCTAssertEqual(track, [Float](repeating: 0, count: 500))
    }
}
