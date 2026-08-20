import Foundation

/// `SynthesizedHarmonyTrackBuilder`(120~122절, 합성음)와 같은 세그먼트+크로스페이드 구조를
/// 그대로 쓰되, 소리 자체는 `ToneSynthesizer`가 아니라 **사용자가 실제로 부른 목소리를
/// `PitchShifter`(WSOLA)로 옮긴 것**으로 채운다(123절, 화음 재설계 2단계).
///
/// **소스 오디오를 구하는 방법**: 각 멜로디 스텝은 이미 `MelodySegmenter`가 정확한
/// onset/duration을 매겨뒀으므로, 그 구간을 원본 녹음(`sourceBuffer`)에서 그대로 잘라 쓰면
/// "이 음을 부를 때의 목소리"를 바로 얻는다 — 예전(85절)엔 실시간 롤링 버퍼에서 음 경계를
/// 거꾸로 추적해야 했던 문제가, 배치 분석 구조에서는 애초에 없다.
///
/// **길이 정확도**: `PitchShifter.shift`는 길이를 "거의" 보존하지만(WSOLA 특성상 ±수백 샘플
/// 오차 가능, `PitchShifterTests.testOutputLengthApproximatelyMatchesInput` 참고) 이
/// 빌더는 overlap-add로 정확한 절대 위치에 써야 하므로, 시프트 결과를 목표 길이에 맞춰
/// 잘라내거나 무음으로 채운다(`fitLength`).
enum VoiceHarmonyTrackBuilder {

    enum Voice: Hashable {
        case melody
        case harmony(ChordGenerator.Interval)
    }

    /// - Parameters:
    ///   - melodySteps: `RecordingAnalyzer.melodySteps`가 만든, harmony/onsetTime/duration이
    ///     채워진 배열.
    ///   - sourceBuffer: 원본 녹음(모노) — 각 스텝의 onset/duration으로 이 배열에서 직접 슬라이싱한다.
    ///   - bufferLength: 결과 트랙 길이(보통 `sourceBuffer.count`와 같음).
    ///   - voice: 만들 성부. `.melody`는 피치 시프트 없이(비율 1) 원본 그대로 쓴다.
    ///   - rate: 샘플레이트.
    ///   - fadeDuration / crossfadeDuration: `SynthesizedHarmonyTrackBuilder`와 동일한 의미
    ///     (무음 경계 fade vs 무음 없는 전환의 크로스페이드).
    /// - Returns: `bufferLength`와 정확히 같은 길이의 배열.
    static func build(
        melodySteps: [MelodyStep],
        sourceBuffer: [Float],
        bufferLength: Int,
        voice: Voice,
        rate: Double,
        fadeDuration: Double = 0.01,
        crossfadeDuration: Double = 0.02
    ) -> [Float] {
        guard bufferLength > 0, rate > 0 else { return [] }

        let segments = voicedSegments(melodySteps: melodySteps, bufferLength: bufferLength, voice: voice, rate: rate)
        var output = [Float](repeating: 0, count: bufferLength)
        guard !segments.isEmpty else { return output }

        let fadeCount = max(0, Int(rate * fadeDuration))
        let crossfadeCount = max(2, Int(rate * crossfadeDuration) / 2 * 2)
        let crossfadeHalf = crossfadeCount / 2

        for (index, segment) in segments.enumerated() {
            let previous = index > 0 ? segments[index - 1] : nil
            let next = index < segments.count - 1 ? segments[index + 1] : nil
            let leadsFromPrevious = previous.map { segment.start - $0.end <= crossfadeHalf } ?? false
            let leadsToNext = next.map { $0.start - segment.end <= crossfadeHalf } ?? false

            let extStart = max(0, segment.start - (leadsFromPrevious ? crossfadeHalf : 0))
            let extEnd = min(bufferLength, segment.end + (leadsToNext ? crossfadeHalf : 0))
            guard extStart < extEnd else { continue }
            let targetLength = extEnd - extStart

            // 소스도 같은 범위(+크로스페이드 확장분)만큼 원본 녹음에서 그대로 슬라이싱한다 —
            // 확장 구간의 목소리가 엄밀히는 다음/이전 음으로 넘어가는 부분일 수 있지만, 크로스
            // 페이드 폭이 짧아서(기본 20ms) 청감상 문제되지 않는다.
            let sourceStart = max(0, min(sourceBuffer.count, extStart))
            let sourceEnd = max(sourceStart, min(sourceBuffer.count, extEnd))
            let sourceSlice = Array(sourceBuffer[sourceStart..<sourceEnd])

            var tone: [Float]
            if segment.pitchRatio == 1.0 {
                tone = sourceSlice
            } else {
                tone = PitchShifter.shift(
                    samples: sourceSlice,
                    pitchRatio: segment.pitchRatio,
                    sampleRate: rate,
                    expectedFrequency: segment.sourceFrequency
                )
            }
            tone = fitLength(tone, to: targetLength)

            let leadingRampCount = leadsFromPrevious ? min(crossfadeCount, tone.count / 2) : min(fadeCount, tone.count / 2)
            if leadingRampCount > 0 {
                for i in 0..<leadingRampCount { tone[i] *= Float(i) / Float(leadingRampCount) }
            }
            let trailingBudget = tone.count - leadingRampCount
            let trailingRampCount = leadsToNext ? min(crossfadeCount, trailingBudget) : min(fadeCount, trailingBudget)
            if trailingRampCount > 0 {
                for i in 0..<trailingRampCount { tone[tone.count - 1 - i] *= Float(i) / Float(trailingRampCount) }
            }

            for i in 0..<tone.count {
                output[extStart + i] += tone[i]
            }
        }

        return output
    }

    private struct Segment {
        let start: Int
        let end: Int
        let pitchRatio: Double
        /// 원본(사용자가 실제로 부른) 음의 주파수 — `PitchShifter`의 그레인 탐색 반경을
        /// 좁히는 데 쓰인다(`expectedFrequency`).
        let sourceFrequency: Double
    }

    private static func voicedSegments(melodySteps: [MelodyStep], bufferLength: Int, voice: Voice, rate: Double) -> [Segment] {
        melodySteps.compactMap { step -> Segment? in
            guard let onset = step.onsetTime, let duration = step.duration, duration > 0 else { return nil }
            let sourceFrequency = NoteNameConverter.frequency(forMIDINote: step.midiNote)

            let pitchRatio: Double
            switch voice {
            case .melody:
                pitchRatio = 1.0
            case .harmony(let interval):
                guard let targetFrequency = step.harmony?.first(where: { $0.interval == interval })?.frequency else { return nil }
                pitchRatio = targetFrequency / sourceFrequency
            }

            let start = max(0, min(bufferLength, Int(onset * rate)))
            let end = max(0, min(bufferLength, Int((onset + duration) * rate)))
            guard start < end else { return nil }
            return Segment(start: start, end: end, pitchRatio: pitchRatio, sourceFrequency: sourceFrequency)
        }
    }

    /// `PitchShifter.shift` 결과는 길이가 "거의" 목표와 같을 뿐이라(WSOLA 특성), overlap-add가
    /// 요구하는 정확한 길이로 맞춘다 — 짧으면 무음으로 채우고, 길면 잘라낸다.
    private static func fitLength(_ samples: [Float], to length: Int) -> [Float] {
        if samples.count == length { return samples }
        if samples.count > length { return Array(samples.prefix(length)) }
        return samples + [Float](repeating: 0, count: length - samples.count)
    }
}
