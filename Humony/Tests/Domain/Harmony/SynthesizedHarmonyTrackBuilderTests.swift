import XCTest
@testable import Humony

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

    // 이웃(직전/직후 세그먼트)이 없는 고립된 스텝은 크로스페이드 대상이 없으니 일반
    // fade-in/out(무음에서 올라오고 무음으로 내려감)만 적용돼야 한다.
    func testHarmonyVoiceUsesMatchingIntervalFrequency() {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.1, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67))]
        let sampleCount = Int(0.1 * rate)
        let fadeDuration = 0.005
        let track = SynthesizedHarmonyTrackBuilder.build(melodySteps: steps, bufferLength: sampleCount, voice: .harmony(.third), rate: rate, fadeDuration: fadeDuration)
        let rawTone = ToneSynthesizer.synthesize(frequency: NoteNameConverter.frequency(forMIDINote: 64), sampleCount: sampleCount, sampleRate: rate)
        let expected = AudioGain.applyFadeInOut(rawTone, fadeSampleCount: Int(rate * fadeDuration))
        XCTAssertEqual(track, expected)
    }

    // 121절 회귀 테스트 — 실기기에서 "화음이 따다다닥 끊겨서 이상하게 들린다"는 제보의 원인이
    // 됐던 동작: 무음 없이 바로 이어지는 두 음의 경계에서 예전엔 완전히 무음(0)까지 떨어졌었다.
    // 크로스페이드로 바뀐 뒤엔 경계 주변에서도 소리가 남아있어야 한다.
    func testContiguousTransitionCrossfadesWithoutDippingToSilence() {
        let steps = [
            step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: nil),
            step(midiNote: 64, onset: 0.2, duration: 0.2, harmony: nil),
        ]
        let bufferLength = Int(0.4 * rate)
        let track = SynthesizedHarmonyTrackBuilder.build(melodySteps: steps, bufferLength: bufferLength, voice: .melody, rate: rate)

        let boundary = Int(0.2 * rate)
        let window = track[max(0, boundary - 50)..<min(bufferLength, boundary + 50)]
        XCTAssertTrue(window.contains { abs($0) > 0.2 }, "크로스페이드 구간이 무음까지 떨어지면 안 된다")
    }

    // 122절 회귀 테스트 — 크로스페이드 구간(기본 20ms)보다 짧은 음이 이웃 두 개와 다 이어지면,
    // 리딩/트레일링 램프가 서로 겹쳐서 음 한가운데가 짜부라지는 아티팩트("지지직" 제보의
    // 원인으로 추정)가 생겼었다. 지금은 두 램프가 절대 겹치지 않게 나눠 가지므로 중간에서도
    // 소리가 남아있어야 한다.
    func testVeryShortSegmentBetweenTwoNotesDoesNotCollapseAmplitude() {
        let steps = [
            step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: nil),
            step(midiNote: 64, onset: 0.2, duration: 0.01, harmony: nil),
            step(midiNote: 67, onset: 0.21, duration: 0.2, harmony: nil),
        ]
        let bufferLength = Int(0.41 * rate)
        let track = SynthesizedHarmonyTrackBuilder.build(melodySteps: steps, bufferLength: bufferLength, voice: .melody, rate: rate)

        let shortSegmentStart = Int(0.2 * rate)
        let shortSegmentEnd = Int(0.21 * rate)
        let middleIndex = (shortSegmentStart + shortSegmentEnd) / 2
        let window = track[max(0, middleIndex - 5)..<min(bufferLength, middleIndex + 5)]
        XCTAssertTrue(window.contains { abs($0) > 0.05 }, "아주 짧은 음 중간이 램프 중첩으로 짜부라지면 안 된다")
    }

    // 크로스페이드 구간에서도 전체 길이는 여전히 정확히 보존돼야 한다(overlap-add라 실수하기 쉬운 지점).
    func testContiguousTransitionStillPreservesBufferLength() {
        let steps = [
            step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: nil),
            step(midiNote: 64, onset: 0.2, duration: 0.2, harmony: nil),
            step(midiNote: 67, onset: 0.4, duration: 0.2, harmony: nil),
        ]
        let bufferLength = Int(0.6 * rate)
        let track = SynthesizedHarmonyTrackBuilder.build(melodySteps: steps, bufferLength: bufferLength, voice: .melody, rate: rate)
        XCTAssertEqual(track.count, bufferLength)
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
