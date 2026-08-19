import XCTest
@testable import HarmonyUp

/// `HarmonyTrackBuilder`(106절에서 `PracticeView+VoiceHarmony.harmonizedTrack`의 조합
/// 로직을 뽑아낸 순수 함수)의 회귀 테스트 — 특히 99·104·105절에서 실제로 겪은 버그 클래스
/// (트랙 길이가 미묘하게 어긋나서 "노래가 빠를수록 화음이 밀리는" 문제)를 직접 겨냥한다.
final class HarmonyTrackBuilderTests: XCTestCase {

    private let rate: Double = 44100

    private func harmonyNote(interval: ChordGenerator.Interval, midiNote: Int) -> ChordGenerator.HarmonyNote {
        ChordGenerator.HarmonyNote(
            interval: interval,
            midiNote: midiNote,
            frequency: NoteNameConverter.frequency(forMIDINote: midiNote),
            pitchClass: midiNote.mod(12)
        )
    }

    /// onset/duration이 정확히 맞물리는(레가토, 간격 없음) 멜로디 스텝 여러 개 — 각 스텝마다
    /// 베이스 화음(멜로디 음보다 12반음 아래)을 갖는다.
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

    private func buffer(seconds: Double) -> [Float] {
        let count = Int(seconds * rate)
        // 전부 0이면 PitchShifter/WORLD가 특이 케이스로 처리할 수 있어, 약한 톤을 채워
        // "실제 목소리 비슷한" 신호를 흉내낸다.
        return (0..<count).map { i in Float(sin(Double(i) * 0.02)) * 0.2 }
    }

    // MARK: - 길이 보존 불변식(105절 크로스페이드 버그가 정확히 이걸 깼었다)

    func testOutputLengthAlwaysMatchesInputBufferLength() {
        for stepCount in [1, 2, 5, 20] {
            let steps = legatoSteps(count: stepCount)
            let totalSeconds = Double(stepCount) * 0.2 + 0.5 // 스텝들 뒤에 여유(무음 꼬리)도 포함
            let voiceBuffer = buffer(seconds: totalSeconds)

            let result = HarmonyTrackBuilder.build(
                melodySteps: steps,
                recentVoiceBuffer: voiceBuffer,
                interval: .bass,
                startStepIndex: nil,
                startTime: 0,
                rate: rate,
                segmentFadeDuration: 0.002,
                isVoiceDoublingEnabled: false
            )

            XCTAssertEqual(result.count, voiceBuffer.count, "스텝 \(stepCount)개 — 출력 길이가 원본 버퍼 길이와 정확히 같아야 함(노래가 빠를수록/스텝이 많을수록 어긋나면 안 됨)")
        }
    }

    func testOutputLengthMatchesEvenWithVoiceDoublingEnabled() {
        let steps = legatoSteps(count: 8)
        let voiceBuffer = buffer(seconds: 2.0)

        let result = HarmonyTrackBuilder.build(
            melodySteps: steps,
            recentVoiceBuffer: voiceBuffer,
            interval: .third,
            startStepIndex: nil,
            startTime: 0,
            rate: rate,
            segmentFadeDuration: 0.002,
            isVoiceDoublingEnabled: true
        )

        XCTAssertEqual(result.count, voiceBuffer.count)
    }

    // MARK: - 그 외 경계 동작

    func testEmptyMelodyStepsReturnsEmpty() {
        let result = HarmonyTrackBuilder.build(
            melodySteps: [],
            recentVoiceBuffer: buffer(seconds: 1.0),
            interval: .bass,
            startStepIndex: nil,
            startTime: 0,
            rate: rate,
            segmentFadeDuration: 0.002,
            isVoiceDoublingEnabled: false
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testOutOfRangeStartStepIndexReturnsEmpty() {
        let steps = legatoSteps(count: 2)
        let result = HarmonyTrackBuilder.build(
            melodySteps: steps,
            recentVoiceBuffer: buffer(seconds: 1.0),
            interval: .bass,
            startStepIndex: 99,
            startTime: 0,
            rate: rate,
            segmentFadeDuration: 0.002,
            isVoiceDoublingEnabled: false
        )
        XCTAssertTrue(result.isEmpty)
    }

    /// 화음이 없는 스텝(쉼표, 온음계 밖 음 등)은 무음(0)이어야 한다.
    func testStepsWithoutHarmonyProduceSilence() {
        let midiNote = 60
        let step = MelodyStep(
            noteName: "rest",
            midiNote: midiNote,
            harmonyVoices: nil,
            harmony: nil, // 이 성부의 화음 없음
            onsetTime: 0,
            duration: 0.3
        )
        let voiceBuffer = buffer(seconds: 0.5)

        let result = HarmonyTrackBuilder.build(
            melodySteps: [step],
            recentVoiceBuffer: voiceBuffer,
            interval: .fifth,
            startStepIndex: nil,
            startTime: 0,
            rate: rate,
            segmentFadeDuration: 0.002,
            isVoiceDoublingEnabled: false
        )

        XCTAssertEqual(result.count, voiceBuffer.count)
        let segEnd = Int(0.3 * rate)
        XCTAssertTrue(result[0..<segEnd].allSatisfy { $0 == 0 }, "화음 없는 스텝 구간은 전부 무음이어야 함")
    }
}
