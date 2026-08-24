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
    /// "기계음처럼 들린다"는 피드백(131절)에 대한 시도 — D4C Love Train 지름길(프레임을
    /// 순수 톤으로 단순화)이 너무 자주 발동하면 기계음처럼, 반대로 아예 꺼버리면(0.0으로
    /// 시도했다가) 화음으로 옮겨진 피치와 실제 비주기성이 안 맞아떨어지는 구간에서
    /// "지지직"거리는 잡음이 생기는 것으로 확인됨 — 두 극단 사이 중간값(0.5)으로 절충
    /// (`PitchShifterWorldAnalysis` 헤더 주석 참고).
    private static let harmonyD4CThreshold: Double = 0.5

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

        guard case .harmony = voice else { return [] }
        var silence: [Float] { [Float](repeating: 0, count: bufferLength) }

        // 성부 하나만 만들 때 쓰는 편의 경로 — 분석을 여기서 만들어 아래 오버로드에 넘긴다.
        // 여러 성부를 만들 거라면 `mixedTrack`을 쓸 것(분석을 한 번만 돌린다).
        guard let analysis = PitchShifterWorldAnalysis(samples: sourceBuffer, sampleRate: rate, d4cThreshold: harmonyD4CThreshold) else { return silence }
        return build(
            melodySteps: melodySteps,
            sourceBuffer: sourceBuffer,
            bufferLength: bufferLength,
            voice: voice,
            rate: rate,
            analysis: analysis,
            fadeDuration: fadeDuration,
            crossfadeDuration: crossfadeDuration
        )
    }

    /// WORLD 분석을 **밖에서 만들어 넘기는** 버전 — 여러 성부를 만들 때 같은 분석을 나눠 쓰기
    /// 위한 것이다.
    ///
    /// **왜 필요한가**: 분석(Dio+StoneMask+CheapTrick+D4C)은 이 파이프라인에서 가장 비싼
    /// 단계이고, 같은 녹음에 대해서는 성부가 몇 개든 결과가 같다. 그런데 성부마다 `build`를
    /// 부르면 그때마다 새로 분석해서, 3성부면 같은 계산이 3번 돌았다 —
    /// `PitchShifterWorldAnalysis` 자신의 설계 주석("분석은 한 번만, 재합성만 반복")이
    /// 호출부에서 무효화돼 있던 셈이다. 60초 녹음에서 UI가 눈에 띄게 멈추는 원인이었다.
    static func build(
        melodySteps: [MelodyStep],
        sourceBuffer: [Float],
        bufferLength: Int,
        voice: Voice,
        rate: Double,
        analysis: PitchShifterWorldAnalysis,
        fadeDuration: Double = 0.01,
        crossfadeDuration: Double = 0.04
    ) -> [Float] {
        guard bufferLength > 0, rate > 0 else { return [] }
        var silence: [Float] { [Float](repeating: 0, count: bufferLength) }

        if case .melody = voice {
            return fitLength(sourceBuffer, to: bufferLength)
        }
        guard case .harmony(let interval) = voice else { return [] }

        let formantRatio = interval.formantRatio
        let segments = voicedSegments(melodySteps: melodySteps, bufferLength: bufferLength, interval: interval, rate: rate)
        guard !segments.isEmpty else { return silence }

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
        return delayedByOnsetOffset(output, interval: interval, rate: rate)
    }

    /// 성부 트랙 전체를 그 성부의 발성 시작 지연만큼 뒤로 민다(145절 휴머나이즈).
    /// 길이는 그대로 유지한다 — 앞은 무음으로 채우고 뒤는 잘라낸다(잘리는 건 트랙 맨 끝의
    /// 잔향/무음 구간이라 실질적 손실이 없다).
    private static func delayedByOnsetOffset(_ track: [Float], interval: ChordGenerator.Interval, rate: Double) -> [Float] {
        let offset = Int(interval.onsetOffsetSeconds * rate)
        guard offset > 0, offset < track.count else { return track }

        var delayed = [Float](repeating: 0, count: track.count)
        delayed.replaceSubrange(offset..<track.count, with: track[0..<(track.count - offset)])
        return delayed
    }

    /// 여러 성부를 **한 번의 분석**으로 만들어 하나의 트랙으로 섞는다.
    ///
    /// 성부마다 `build`를 부르면 녹음 전체 WORLD 분석이 성부 수만큼 반복된다 — 이 함수는
    /// 분석을 한 번만 만들어 전부가 공유하게 한다. 화음 성부가 하나도 없으면(멜로디만) 분석
    /// 자체를 만들지 않는다.
    ///
    /// - Parameter backingGain: 화음 3성부에 걸 음량 배율 — 리드 멜로디가 앞으로 나오게 한다
    ///   (128절). 멜로디에는 걸지 않는다.
    static func mixedTrack(
        melodySteps: [MelodyStep],
        sourceBuffer: [Float],
        bufferLength: Int,
        voices: [Voice],
        rate: Double,
        backingGain: Float = 0.65,
        fadeDuration: Double = 0.01,
        crossfadeDuration: Double = 0.04
    ) -> [Float] {
        guard bufferLength > 0, rate > 0, !voices.isEmpty else { return [] }

        let tracks = voiceTracks(
            melodySteps: melodySteps,
            sourceBuffer: sourceBuffer,
            bufferLength: bufferLength,
            voices: voices,
            rate: rate,
            backingGain: backingGain,
            fadeDuration: fadeDuration,
            crossfadeDuration: crossfadeDuration
        )
        return AudioGain.mix(tracks: tracks)
    }

    /// `mixedTrack`의 스테레오 판 — 성부를 좌우로 벌려서 섞는다.
    ///
    /// **왜 필요한가(145절)**: 사람 귀는 같은 방향에서 겹쳐 나는 소리를 잘 분리하지 못한다.
    /// 네 성부를 전부 모노 정중앙에 더하면 화음이 "여러 사람"이 아니라 "두꺼워진 한 사람"으로
    /// 들린다 — 실제 아카펠라 녹음이 자연스러운 큰 이유 하나가 성부가 공간적으로 떨어져 있다는
    /// 점이다. 위치 값은 이미 `ChordGenerator.Interval.pan`에 정의돼 있었는데(52절에 근거까지
    /// 적어두고) 재생 경로가 모노라 한 번도 쓰인 적이 없었다.
    ///
    /// 리드 멜로디는 정중앙에 둔다 — 화음이 좌우에서 리드를 감싸는 배치가 되어야 리드가
    /// 묻히지 않는다.
    static func mixedStereoTrack(
        melodySteps: [MelodyStep],
        sourceBuffer: [Float],
        bufferLength: Int,
        voices: [Voice],
        rate: Double,
        backingGain: Float = 0.65,
        fadeDuration: Double = 0.01,
        crossfadeDuration: Double = 0.04
    ) -> (left: [Float], right: [Float]) {
        guard bufferLength > 0, rate > 0, !voices.isEmpty else { return ([], []) }

        let tracks = voiceTracks(
            melodySteps: melodySteps,
            sourceBuffer: sourceBuffer,
            bufferLength: bufferLength,
            voices: voices,
            rate: rate,
            backingGain: backingGain,
            fadeDuration: fadeDuration,
            crossfadeDuration: crossfadeDuration
        )
        let panned = zip(voices, tracks).map { voice, samples in
            AudioGain.PannedTrack(samples: samples, pan: stereoPan(for: voice))
        }
        return AudioGain.mixToStereo(tracks: panned)
    }

    /// 성부를 스테레오 어디에 놓을지 — 리드는 정중앙, 화음은 `Interval.pan`을 따른다.
    /// 140절과 같은 이유로 위치 값 자체는 `Interval` 한 곳에만 둔다(화면마다/함수마다 따로
    /// 적으면 언젠가 반드시 갈린다).
    private static func stereoPan(for voice: Voice) -> Float {
        switch voice {
        case .melody: return 0
        case .harmony(let interval): return interval.pan
        }
    }

    /// 성부별 트랙을 만든다 — 모노/스테레오 믹스가 공유하는 공통 부분.
    /// WORLD 분석은 성부가 몇 개든 **한 번만** 돈다(143절).
    private static func voiceTracks(
        melodySteps: [MelodyStep],
        sourceBuffer: [Float],
        bufferLength: Int,
        voices: [Voice],
        rate: Double,
        backingGain: Float,
        fadeDuration: Double,
        crossfadeDuration: Double
    ) -> [[Float]] {
        let needsAnalysis = voices.contains { if case .harmony = $0 { return true } else { return false } }
        let analysis = needsAnalysis
            ? PitchShifterWorldAnalysis(samples: sourceBuffer, sampleRate: rate, d4cThreshold: harmonyD4CThreshold)
            : nil

        return voices.map { voice in
            if case .melody = voice {
                return fitLength(sourceBuffer, to: bufferLength)
            }
            // 분석에 실패하면(빈 입력 등) 그 성부는 무음으로 둔다 — 나머지 성부는 그대로 들린다.
            guard let analysis else { return [Float](repeating: 0, count: bufferLength) }
            let track = build(
                melodySteps: melodySteps,
                sourceBuffer: sourceBuffer,
                bufferLength: bufferLength,
                voice: voice,
                rate: rate,
                analysis: analysis,
                fadeDuration: fadeDuration,
                crossfadeDuration: crossfadeDuration
            )
            return track.map { $0 * backingGain }
        }
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
            // 성부별 미세 디튠(145절) — 목표 음에서 몇 cent만 비껴놓아야 세 성부가 하나로
            // 뭉치지 않고 "여러 명"으로 들린다. 근거는 `Interval.detuneCents` 주석 참고.
            let pitchRatio = targetFrequency / sourceFrequency * interval.detuneRatio

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
