import Foundation

/// 멜로디 스텝 시퀀스(음이름/MIDI/화음/시작시각/길이)를 원본 녹음과 같은 길이의 합성음
/// 트랙으로 바꾼다 — 멜로디 자신도, 베이스/3도/5도 화음도 전부 `ToneSynthesizer`로 만든다
/// (120절, 화음 재설계 1단계: 목소리 피치시프트를 완전히 배제하고 합성음만으로 화음 선택/
/// 타이밍부터 검증한다).
///
/// **길이 보존 계약**: 결과는 항상 `bufferLength`와 정확히 같은 길이다 — 음이 없는 구간
/// (쉼표, 스텝 사이 빈틈)은 무음(0)으로 채운다. 이전에 화음 파이프라인(`harmonizedTrack`)이
/// 이 불변식 없이 `PracticeView` 메서드 안에 있다가 "노래가 빠를수록 화음이 밀리는" 버그를
/// 냈던 적이 있어(CLAUDE.md 코딩 컨벤션 참고), 이번엔 처음부터 순수 함수+유닛테스트로
/// 이 불변식을 보장한다.
enum SynthesizedHarmonyTrackBuilder {

    enum Voice: Hashable {
        case melody
        case harmony(ChordGenerator.Interval)
    }

    /// - Parameters:
    ///   - melodySteps: 녹음 전체의 멜로디 스텝 시퀀스(`RecordingAnalyzer.melodySteps`가 만든,
    ///     harmony/onsetTime/duration이 채워진 배열).
    ///   - bufferLength: 결과 트랙이 맞춰야 할 길이(원본 녹음 샘플 개수).
    ///   - voice: 만들 성부 — 멜로디 자신이거나 화음(베이스/3도/5도) 중 하나.
    ///   - rate: 샘플레이트.
    ///   - segmentFadeDuration: 스텝 경계 클릭 방지용 페이드 길이(초).
    /// - Returns: `bufferLength`와 정확히 같은 길이의 배열.
    static func build(
        melodySteps: [MelodyStep],
        bufferLength: Int,
        voice: Voice,
        rate: Double,
        segmentFadeDuration: Double = 0.01
    ) -> [Float] {
        guard bufferLength > 0, rate > 0 else { return [] }

        let segmentFadeCount = max(1, Int(rate * segmentFadeDuration))
        var output: [Float] = []
        output.reserveCapacity(bufferLength)
        var cursor = 0

        for step in melodySteps {
            guard let onset = step.onsetTime, let duration = step.duration, duration > 0 else { continue }
            let segStart = max(0, min(bufferLength, Int(onset * rate)))
            let segEnd = max(0, min(bufferLength, Int((onset + duration) * rate)))
            guard segStart < segEnd, segStart >= cursor else { continue }

            if segStart > cursor {
                output.append(contentsOf: [Float](repeating: 0, count: segStart - cursor))
            }

            if let frequency = frequency(for: voice, step: step) {
                let tone = ToneSynthesizer.synthesize(frequency: frequency, sampleCount: segEnd - segStart, sampleRate: rate)
                output.append(contentsOf: AudioGain.applyFadeInOut(tone, fadeSampleCount: min(segmentFadeCount, tone.count / 2)))
            } else {
                output.append(contentsOf: [Float](repeating: 0, count: segEnd - segStart))
            }
            cursor = segEnd
        }

        if cursor < bufferLength {
            output.append(contentsOf: [Float](repeating: 0, count: bufferLength - cursor))
        }
        return output
    }

    private static func frequency(for voice: Voice, step: MelodyStep) -> Double? {
        switch voice {
        case .melody:
            return NoteNameConverter.frequency(forMIDINote: step.midiNote)
        case .harmony(let interval):
            return step.harmony?.first { $0.interval == interval }?.frequency
        }
    }
}
