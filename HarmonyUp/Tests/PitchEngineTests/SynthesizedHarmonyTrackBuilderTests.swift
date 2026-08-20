import XCTest
@testable import HarmonyUp

/// `SynthesizedHarmonyTrackBuilder`(화음을 처음 넣었을 때의 TonePlayer 합성음으로 되돌린
/// 2026-08-20 변경)의 회귀 테스트 — `HarmonyTrackBuilderTests`와 같은 불변식(길이 보존,
/// 화음 없는 스텝은 무음)을 같은 방식으로 검증한다. 소스가 목소리가 아니라 합성음이라
/// `recentVoiceBuffer` 대신 `bufferLength`(Int)만 받는다는 시그니처 차이만 있다.
final class SynthesizedHarmonyTrackBuilderTests: XCTestCase {

    private let rate: Double = 44100

    private func harmonyNote(interval: ChordGenerator.Interval, midiNote: Int) -> ChordGenerator.HarmonyNote {
        ChordGenerator.HarmonyNote(
            interval: interval,
            midiNote: midiNote,
            frequency: NoteNameConverter.frequency(forMIDINote: midiNote),
            pitchClass: midiNote.mod(12)
        )
    }

    private func legatoSteps(count: Int, stepDuration: Double = 0.2) -> [MelodyStep] {
        (0..<count).map { i in
            let midiNote = 60 + i
            return MelodyStep(
                noteName: "note\(i)",
                midiNote: midiNote,
                harmonyVoices: nil,
                harmony: [harmonyNote(interval: .bass, midiNote: midiNote - 12)],
                onsetTime: Double(i) * stepDuration,
                duration: stepDuration
            )
        }
    }

    // MARK: - 길이 보존 불변식

    func testOutputLengthAlwaysMatchesBufferLength() {
        for stepCount in [1, 2, 5, 20] {
            let steps = legatoSteps(count: stepCount)
            let totalSeconds = Double(stepCount) * 0.2 + 0.5
            let bufferLength = Int(totalSeconds * rate)

            let result = SynthesizedHarmonyTrackBuilder.build(
                melodySteps: steps,
                bufferLength: bufferLength,
                interval: .bass,
                startStepIndex: nil,
                startTime: 0,
                rate: rate,
                segmentFadeDuration: 0.002
            )

            XCTAssertEqual(result.count, bufferLength, "스텝 \(stepCount)개 — 출력 길이가 bufferLength와 정확히 같아야 함")
        }
    }

    // MARK: - 그 외 경계 동작

    func testEmptyMelodyStepsReturnsEmpty() {
        let result = SynthesizedHarmonyTrackBuilder.build(
            melodySteps: [],
            bufferLength: Int(1.0 * rate),
            interval: .bass,
            startStepIndex: nil,
            startTime: 0,
            rate: rate,
            segmentFadeDuration: 0.002
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testOutOfRangeStartStepIndexReturnsEmpty() {
        let steps = legatoSteps(count: 2)
        let result = SynthesizedHarmonyTrackBuilder.build(
            melodySteps: steps,
            bufferLength: Int(1.0 * rate),
            interval: .bass,
            startStepIndex: 99,
            startTime: 0,
            rate: rate,
            segmentFadeDuration: 0.002
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// 화음이 없는 스텝(쉼표, 온음계 밖 음 등)은 무음(0)이어야 한다.
    func testStepsWithoutHarmonyProduceSilence() {
        let step = MelodyStep(
            noteName: "rest",
            midiNote: 60,
            harmonyVoices: nil,
            harmony: nil, // 이 성부의 화음 없음
            onsetTime: 0,
            duration: 0.3
        )
        let bufferLength = Int(0.5 * rate)

        let result = SynthesizedHarmonyTrackBuilder.build(
            melodySteps: [step],
            bufferLength: bufferLength,
            interval: .fifth,
            startStepIndex: nil,
            startTime: 0,
            rate: rate,
            segmentFadeDuration: 0.002
        )

        XCTAssertEqual(result.count, bufferLength)
        let segEnd = Int(0.3 * rate)
        XCTAssertTrue(result[0..<segEnd].allSatisfy { $0 == 0 }, "화음 없는 스텝 구간은 전부 무음이어야 함")
    }

    /// 화음이 있는 스텝은 실제로 소리가 나야 한다(전부 무음이면 톤 합성 자체가 빠진 것).
    func testStepsWithHarmonyProduceNonSilentAudio() {
        let steps = legatoSteps(count: 3)
        let bufferLength = Int(1.0 * rate)

        let result = SynthesizedHarmonyTrackBuilder.build(
            melodySteps: steps,
            bufferLength: bufferLength,
            interval: .bass,
            startStepIndex: nil,
            startTime: 0,
            rate: rate,
            segmentFadeDuration: 0.002
        )

        XCTAssertTrue(result.contains { $0 != 0 }, "화음이 있는 스텝 구간엔 합성된 톤이 있어야 함")
    }
}
