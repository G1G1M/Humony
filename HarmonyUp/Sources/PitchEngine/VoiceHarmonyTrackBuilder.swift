import Foundation

/// `SynthesizedHarmonyTrackBuilder`(120~122절, 합성음)와 같은 세그먼트+크로스페이드 구조를
/// 그대로 쓰되, 소리 자체는 `ToneSynthesizer`가 아니라 **사용자가 실제로 부른 목소리를
/// 피치시프트로 옮긴 것**으로 채운다(123절, 화음 재설계 2단계).
///
/// **125절, WSOLA → WORLD로 교체**: 123절엔 `PitchShifter`(WSOLA)를 썼는데 실기기 청취에서
/// "어색하다"는 평가를 받았다 — WSOLA 계열은 피치를 올리면 포먼트도 같이 따라 올라가서
/// (성도 모양이 만드는 음색이 원래 음높이에 묶여 있음) 특히 3도/5도처럼 크게 옮길 때
/// "다람쥐 소리"에 가까워지는 원리적 한계가 있다. `PitchShifterWorld`(WORLD 보코더, 124~125절
/// 복원)는 F0(피치)와 스펙트럼 포락선(포먼트)을 애초에 분리해서 분석하므로, 포먼트를 원본
/// 그대로 유지한 채 피치만 옮길 수 있다 — 그 한계를 원리적으로 피해간다.
///
/// **소스 오디오를 구하는 방법**: 각 멜로디 스텝은 이미 `MelodySegmenter`가 정확한
/// onset/duration을 매겨뒀으므로, 그 구간을 원본 녹음(`sourceBuffer`)에서 그대로 잘라 쓰면
/// "이 음을 부를 때의 목소리"를 바로 얻는다 — 예전(85절)엔 실시간 롤링 버퍼에서 음 경계를
/// 거꾸로 추적해야 했던 문제가, 배치 분석 구조에서는 애초에 없다.
///
/// **길이 정확도**: `PitchShifterWorld.shift`는 항상 입력과 정확히 같은 길이를 돌려주지만
/// (브릿지 계약, `PitchShifterWorldTests.testOutputLengthMatchesInput` 참고), overlap-add가
/// 요구하는 목표 길이(크로스페이드 확장분 포함)와는 여전히 다를 수 있어 `fitLength`로
/// 안전하게 맞춘다(WSOLA 시절의 근사 길이 문제와는 다른 이유로 계속 필요).
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

        if case .melody = voice {
            // 원본 녹음은 이미 연속된 오디오다 — MelodySegmenter가 "인식된 음"으로 확정 못한
            // 짧은 구간(숨소리/자음/저신뢰도 전환)은 MelodyStep 목록에 아예 없어서, 세그먼트로
            // 잘라 다시 이어붙이면 그 구간이 완전한 무음으로 재생돼 "딱딱 끊긴다"는 제보로
            // 이어졌다(128절). 멜로디는 피치 시프트가 없으므로(비율 1) 세그먼트 재구성 자체가
            // 불필요 — 길이만 맞춰 원본을 그대로 돌려준다.
            return fitLength(sourceBuffer, to: bufferLength)
        }

        guard case .harmony(let interval) = voice else { return [] }
        let segments = voicedSegments(melodySteps: melodySteps, bufferLength: bufferLength, interval: interval, rate: rate)
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

            // 128절: 크로스페이드 확장분을 이웃 세그먼트(다른 음높이)의 실제 목소리에서
            // 빌리지 않는다 — 그러면 "다음 음의 목소리"가 "현재 화음 음정"으로 잘못 옮겨진
            // 소리가 크로스페이드 안쪽(가중치가 큰 구간)에 섞인다. 대신 이 세그먼트 자신의
            // 오디오를 경계에서 거울반사해서 확장분을 채운다 — 이웃 침범 없이, 무음도 아닌
            // "같은 음의 실제 신호"로 크로스페이드 목적을 유지한다.
            let sourceSlice = mirrorExtendedSlice(
                sourceBuffer: sourceBuffer,
                segmentStart: segment.start,
                segmentEnd: segment.end,
                extStart: extStart,
                extEnd: extEnd
            )

            var tone: [Float]
            if segment.pitchRatio == 1.0 {
                tone = sourceSlice
            } else {
                tone = PitchShifterWorld.shift(
                    samples: sourceSlice,
                    pitchRatio: segment.pitchRatio,
                    sampleRate: rate
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

    private static func voicedSegments(melodySteps: [MelodyStep], bufferLength: Int, interval: ChordGenerator.Interval, rate: Double) -> [Segment] {
        melodySteps.compactMap { step -> Segment? in
            guard let onset = step.onsetTime, let duration = step.duration, duration > 0 else { return nil }
            let sourceFrequency = NoteNameConverter.frequency(forMIDINote: step.midiNote)

            guard let targetFrequency = step.harmony?.first(where: { $0.interval == interval })?.frequency else { return nil }
            let pitchRatio = targetFrequency / sourceFrequency

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

    /// 128절 — 크로스페이드 확장 구간(`extStart..<extEnd`)을 이 세그먼트 자신의 오디오
    /// (`segmentStart..<segmentEnd`)만으로 채운다. 세그먼트 경계 바로 안쪽 샘플부터 거울처럼
    /// 뒤집어서 바깥으로 이어 붙이는 방식(대칭 반사 패딩)이라, 이웃 세그먼트(다른 음높이)의
    /// 오디오는 전혀 섞이지 않고 경계에서 값이 자연스럽게 이어진다(불연속 없음).
    /// `internal`로 열어둔 이유: 유닛테스트에서 이웃 침범이 실제로 없는지 직접 검증하기 위함
    /// (`MelodySegmenter.absorbShortRuns`와 같은 관례).
    static func mirrorExtendedSlice(
        sourceBuffer: [Float],
        segmentStart: Int,
        segmentEnd: Int,
        extStart: Int,
        extEnd: Int
    ) -> [Float] {
        let clampedStart = max(0, min(sourceBuffer.count, segmentStart))
        let clampedEnd = max(clampedStart, min(sourceBuffer.count, segmentEnd))
        let core = Array(sourceBuffer[clampedStart..<clampedEnd])
        guard !core.isEmpty else { return [Float](repeating: 0, count: max(0, extEnd - extStart)) }

        let leadingCount = max(0, clampedStart - extStart)
        let trailingCount = max(0, extEnd - clampedEnd)
        return mirror(core, count: leadingCount, fromStart: true) + core + mirror(core, count: trailingCount, fromStart: false)
    }

    /// `core`의 시작(또는 끝) 근처 `count`개를 뒤집어 만든 확장분. `count`가 `core.count`보다
    /// 크면(세그먼트 자체가 크로스페이드 확장보다 짧은 극단적인 경우 — 최소 음 길이 0.18초
    /// ≈ 7900샘플이 크로스페이드 확장 최대 10ms ≈ 441샘플보다 훨씬 길어 실전에선 거의 없다)
    /// 남는 만큼은 가장자리 샘플을 반복해 방어적으로 채운다.
    private static func mirror(_ core: [Float], count: Int, fromStart: Bool) -> [Float] {
        guard count > 0, !core.isEmpty else { return [] }
        let mirrorCount = min(count, core.count)
        if fromStart {
            var result = Array(core.prefix(mirrorCount).reversed())
            if count > mirrorCount { result = [Float](repeating: core[0], count: count - mirrorCount) + result }
            return result
        } else {
            var result = Array(core.suffix(mirrorCount).reversed())
            if count > mirrorCount { result += [Float](repeating: core[core.count - 1], count: count - mirrorCount) }
            return result
        }
    }
}
