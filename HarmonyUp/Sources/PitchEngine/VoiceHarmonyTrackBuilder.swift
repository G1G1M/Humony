import Foundation

/// 129절, "전체 한 번 분석 + F0곡선 재합성" 구조 개선의 2단계 — 화음 성부(베이스/3도/5도)를
/// 만들 때 더 이상 멜로디 스텝(음)마다 원본을 잘라 WORLD를 독립적으로 다시 돌리지 않는다.
/// 대신 원본 녹음 전체로 `PitchShifterWorldAnalysis`를 **한 번만** 만들고, 그 F0 곡선의
/// 스텝에 해당하는 구간만 목표 화음 비율로 바꿔치기한 뒤 **한 번만** 재합성한다 — 목소리
/// 전체가 하나로 이어진 채 처리되므로, 세그먼트를 잘라 각각 분석-재합성하고 크로스페이드로
/// 이어붙이던 예전 방식(123~128절)에서 남던 "이어붙인 티"가 원리적으로 사라진다.
///
/// **이전 세대(128절)와의 차이**: 예전엔 스텝마다 원본 오디오 조각을 잘라 각각 WORLD로
/// 재합성한 뒤, 그 결과물끼리 진폭 크로스페이드로 이어붙였다(다른 음높이 신호 두 개를
/// 섞는 방식). 지금은 처음부터 끝까지 **하나의 연속된 오디오**만 있고, 그 안의 F0 값이
/// 스텝 경계에서 부드럽게(글리산도) 바뀔 뿐이다 — 그래서 "크로스페이드"의 의미도 바뀌었다:
/// 진폭을 섞는 게 아니라 **F0 곡선 자체를 선형보간**해서 피치 전환을 매끄럽게 만든다.
/// 스텝 사이가 무음/숨쉬는 구간(진짜 쉼표)일 때만 진폭 마스킹(페이드)으로 소리를 낮춘다.
enum VoiceHarmonyTrackBuilder {

    enum Voice: Hashable {
        case melody
        case harmony(ChordGenerator.Interval)
    }

    /// 132절 — WORLD 기본값(0.85, `world::kThreshold`)보다 낮춘 실험값. 화음 성부가
    /// "기계음처럼 들린다"는 피드백(131절)에 대한 첫 시도 — 값을 0으로 낮춰 D4C Love Train
    /// 지름길(프레임을 순수 톤으로 단순화)을 아예 끄고, 모든 유성음 프레임에서 실제 비주기성
    /// (숨소리/노이즈 질감)을 정교하게 계산하도록 한다. 극단값으로 먼저 시험해 방향성 자체를
    /// 확인하고, 너무 거칠거나 노이즈가 심하면 값을 올려 되돌아올 계획(`PitchShifterWorldAnalysis`
    /// 헤더 주석 참고).
    private static let harmonyD4CThreshold: Double = 0.0

    /// - Parameters:
    ///   - melodySteps: `RecordingAnalyzer.melodySteps`가 만든, harmony/onsetTime/duration이
    ///     채워진 배열.
    ///   - sourceBuffer: 원본 녹음(모노) — 화음 성부는 이 배열 전체를 한 번만 분석한다.
    ///   - bufferLength: 결과 트랙 길이(보통 `sourceBuffer.count`와 같음).
    ///   - voice: 만들 성부. `.melody`는 피치 시프트 없이(비율 1) 원본 그대로 쓴다.
    ///   - rate: 샘플레이트.
    ///   - fadeDuration: 진짜 무음/숨쉬는 구간 경계에서 클릭음을 막는 짧은 페이드.
    ///   - crossfadeDuration: 인접한(무음 없이 이어지는) 두 화음 스텝 사이에서 F0를
    ///     선형보간할 전환 폭.
    /// - Returns: `bufferLength`와 정확히 같은 길이의 배열.
    static func build(
        melodySteps: [MelodyStep],
        sourceBuffer: [Float],
        bufferLength: Int,
        voice: Voice,
        rate: Double,
        fadeDuration: Double = 0.01,
        crossfadeDuration: Double = 0.04
    ) -> [Float] {
        guard bufferLength > 0, rate > 0 else { return [] }

        if case .melody = voice {
            // 원본 녹음은 이미 연속된 오디오다 — MelodySegmenter가 "인식된 음"으로 확정 못한
            // 짧은 구간(숨소리/자음/저신뢰도 전환)은 MelodyStep 목록에 아예 없어서, 세그먼트로
            // 잘라 다시 이어붙이면 그 구간이 완전한 무음으로 재생돼 "딱딱 끊긴다"는 제보로
            // 이어졌다(128절). 멜로디는 피치 시프트가 없으므로(비율 1) 세그먼트 재구성 자체가
            // 불필요 — 길이만 맞춰 원본을 그대로 돌려준다.
            return fitLength(sourceBuffer, to: bufferLength)
        }

        guard case .harmony(let interval) = voice else { return [] }
        let formantRatio = interval.formantRatio
        let segments = voicedSegments(melodySteps: melodySteps, bufferLength: bufferLength, interval: interval, rate: rate)
        var silence: [Float] { [Float](repeating: 0, count: bufferLength) }
        guard !segments.isEmpty else { return silence }

        guard let analysis = PitchShifterWorldAnalysis(samples: sourceBuffer, sampleRate: rate, d4cThreshold: harmonyD4CThreshold) else { return silence }

        let fadeCount = max(0, Int(rate * fadeDuration))
        let crossfadeCount = max(2, Int(rate * crossfadeDuration) / 2 * 2)
        let crossfadeHalf = crossfadeCount / 2

        let modifiedF0 = harmonyF0Curve(analysis: analysis, segments: segments, crossfadeHalf: crossfadeHalf, rate: rate)
        let synthesized = analysis.synthesize(f0: modifiedF0, formantRatio: formantRatio)
        let fitted = fitLength(synthesized, to: bufferLength)

        let envelope = amplitudeEnvelope(segments: segments, bufferLength: bufferLength, fadeCount: fadeCount, crossfadeHalf: crossfadeHalf)

        var output = [Float](repeating: 0, count: bufferLength)
        for i in 0..<bufferLength {
            output[i] = fitted[i] * envelope[i]
        }
        return output
    }

    private struct Segment {
        let start: Int
        let end: Int
        let pitchRatio: Double
    }

    private static func voicedSegments(melodySteps: [MelodyStep], bufferLength: Int, interval: ChordGenerator.Interval, rate: Double) -> [Segment] {
        melodySteps.compactMap { step -> Segment? in
            guard let onset = step.onsetTime, let duration = step.duration, duration > 0 else { return nil }
            let sourceFrequency = NoteNameConverter.frequency(forMIDINote: step.midiNote)

            guard let targetFrequency = step.harmony?.first(where: { $0.interval == interval })?.frequency else { return nil }
            let pitchRatio = targetFrequency / sourceFrequency

            let start = max(0, min(bufferLength, Int(onset * rate)))
            let end = max(0, min(bufferLength, Int((onset + duration) * rate)))
            guard start < end else { return nil }
            return Segment(start: start, end: end, pitchRatio: pitchRatio)
        }
    }

    /// `analysis.f0`(원본 곡선)를 바탕으로, 각 세그먼트 구간의 프레임은 그 세그먼트의
    /// `pitchRatio`만큼 스케일하고, 인접한(무음 없이 이어지는) 두 세그먼트 사이는 두 비율을
    /// 선형보간해 F0가 계단 없이 매끄럽게 전환되도록 만든다. 세그먼트에 속하지 않는 프레임은
    /// 원본 F0를 그대로 둔다 — 그 구간은 어차피 `amplitudeEnvelope`가 무음으로 마스킹하므로
    /// 값 자체는 들리지 않지만, 임의로 0을 넣지 않는 편이 이후 디버깅(로그로 F0 곡선을 볼 때)에
    /// 더 정직하다.
    private static func harmonyF0Curve(analysis: PitchShifterWorldAnalysis, segments: [Segment], crossfadeHalf: Int, rate: Double) -> [Double] {
        var curve = analysis.f0
        let frameRate = 1000.0 / analysis.framePeriodMs
        func frame(forSample sample: Int) -> Int {
            max(0, min(analysis.f0Length - 1, Int((Double(sample) / rate) * frameRate)))
        }

        for segment in segments {
            let startFrame = frame(forSample: segment.start)
            let endFrame = frame(forSample: segment.end)
            guard startFrame < endFrame else { continue }
            for f in startFrame..<endFrame {
                let original = analysis.f0[f]
                curve[f] = original > 0 ? original * segment.pitchRatio : 0
            }
        }

        for i in 0..<(segments.count - 1) {
            let current = segments[i]
            let next = segments[i + 1]
            let gap = next.start - current.end
            guard gap >= 0, gap <= crossfadeHalf * 2 else { continue }

            let blendStartFrame = frame(forSample: max(current.start, current.end - crossfadeHalf))
            let blendEndFrame = frame(forSample: min(next.start + crossfadeHalf, next.end))
            guard blendStartFrame < blendEndFrame else { continue }

            let span = Double(blendEndFrame - blendStartFrame)
            for f in blendStartFrame..<blendEndFrame {
                let t = Double(f - blendStartFrame) / span
                let ratio = current.pitchRatio * (1 - t) + next.pitchRatio * t
                let original = analysis.f0[f]
                curve[f] = original > 0 ? original * ratio : 0
            }
        }

        return curve
    }

    /// 세그먼트 core는 항상 1.0(들림). 인접 세그먼트끼리는(위 F0 보간 구간과 같은 판정 기준)
    /// 오디오가 이미 연속이라 그 사이 gap도 1.0으로 유지 — 진짜 무음/숨쉬는 구간에서 시작/
    /// 끝나는 경계에서만 짧게 0으로 페이드해 클릭음을 막는다.
    private static func amplitudeEnvelope(segments: [Segment], bufferLength: Int, fadeCount: Int, crossfadeHalf: Int) -> [Float] {
        var envelope = [Float](repeating: 0, count: bufferLength)

        for (index, segment) in segments.enumerated() {
            let clampedStart = max(0, min(bufferLength, segment.start))
            let clampedEnd = max(clampedStart, min(bufferLength, segment.end))
            for s in clampedStart..<clampedEnd { envelope[s] = 1.0 }

            let previous = index > 0 ? segments[index - 1] : nil
            let next = index < segments.count - 1 ? segments[index + 1] : nil
            let connectsToPrevious = previous.map { segment.start - $0.end <= crossfadeHalf * 2 } ?? false
            let connectsToNext = next.map { $0.start - segment.end <= crossfadeHalf * 2 } ?? false

            if connectsToPrevious, let previous {
                let bridgeStart = max(0, min(bufferLength, previous.end))
                let bridgeEnd = max(bridgeStart, min(bufferLength, segment.start))
                for s in bridgeStart..<bridgeEnd { envelope[s] = 1.0 }
            } else {
                let fadeStart = max(0, segment.start - fadeCount)
                let count = segment.start - fadeStart
                for i in 0..<count {
                    let s = fadeStart + i
                    guard s >= 0, s < bufferLength else { continue }
                    envelope[s] = max(envelope[s], Float(i) / Float(max(1, count)))
                }
            }

            if !connectsToNext {
                let fadeEnd = min(bufferLength, segment.end + fadeCount)
                let count = fadeEnd - segment.end
                for i in 0..<count {
                    let s = segment.end + i
                    guard s >= 0, s < bufferLength else { continue }
                    envelope[s] = max(envelope[s], Float(count - i) / Float(max(1, count)))
                }
            }
        }

        return envelope
    }

    /// `PitchShifterWorldAnalysis.synthesize` 결과는 항상 원본(=`sourceBuffer`) 길이와 같지만
    /// (브릿지 계약, `PitchShifterWorldAnalysisTests.testSynthesizeOutputLengthMatchesInputLength`
    /// 참고), 호출자가 요청한 `bufferLength`와는 여전히 다를 수 있어 안전하게 맞춘다.
    private static func fitLength(_ samples: [Float], to length: Int) -> [Float] {
        if samples.count == length { return samples }
        if samples.count > length { return Array(samples.prefix(length)) }
        return samples + [Float](repeating: 0, count: length - samples.count)
    }
}
