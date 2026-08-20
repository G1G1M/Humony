import Foundation

/// 멜로디 스텝 시퀀스(음이름/MIDI/화음/시작시각/길이)를 원본 녹음과 같은 길이의 합성음
/// 트랙으로 바꾼다 — 멜로디 자신도, 베이스/3도/5도 화음도 전부 `ToneSynthesizer`로 만든다
/// (120절, 화음 재설계 1단계: 목소리 피치시프트를 완전히 배제하고 합성음만으로 화음 선택/
/// 타이밍부터 검증한다).
///
/// **길이 보존 계약**: 결과는 항상 `bufferLength`와 정확히 같은 길이다 — 음이 없는 구간
/// (쉼표, 스텝 사이 빈틈)은 무음(0)으로 채운다. 고정 길이 버퍼에 세그먼트를 직접 겹쳐 쓰는
/// (append가 아니라 overlap-add) 방식이라, 세그먼트 경계 계산이 어긋나도 전체 길이 자체는
/// 항상 보장된다(CLAUDE.md 코딩 컨벤션의 "노래가 빠를수록 화음이 밀리는" 버그 교훈 참고).
///
/// **121절, 진짜 크로스페이드로 수정**: 처음 버전은 스텝마다 무조건 무음까지 페이드아웃/
/// 페이드인했다 — `ChordGenerator`가 멜로디 음 하나하나마다 새 화음을 계산하므로(v1, 101절)
/// 화음 성부는 멜로디의 모든 음 전환마다 같이 바뀌는데, 그때마다 4성부가 동시에 무음까지
/// 뚝 떨어졌다 다시 올라오는 게 "따다다닥" 하는 끊김/노이즈로 들린다는 실기기 제보를 받았다
/// (2026-08-20). 무음이 실제로 없는 전환(대부분의 경우)에는 이전 음의 꼬리와 다음 음의
/// 머리를 겹쳐서(overlap-add) 상호 보완적인 선형 램프(1→0과 0→1의 합이 항상 1)로 잇는
/// **진짜 크로스페이드**로 바꿨다 — 무음으로 갈라진 경계(맨 처음/쉼표 뒤)에만 일반
/// fade-in/out을 쓴다.
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
    ///   - fadeDuration: 무음 경계(맨 처음, 쉼표 뒤/앞)에서 올라오거나 내려가는 일반 페이드 길이(초).
    ///   - crossfadeDuration: 무음 없이 바로 이어지는 음 전환(대부분의 멜로디 전환)을 자연스럽게
    ///     겹쳐 잇는 크로스페이드 길이(초) — `fadeDuration`보다 살짝 길게 잡아 전환을 더 부드럽게 한다.
    /// - Returns: `bufferLength`와 정확히 같은 길이의 배열.
    static func build(
        melodySteps: [MelodyStep],
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
        // 크로스페이드 창은 경계를 중심으로 좌우 대칭이어야 두 세그먼트의 램프 합이 항상 1이
        // 된다(아래 "왜 절반씩 파고드는지" 참고) — 그래서 짝수로 맞춘다.
        let crossfadeCount = max(2, Int(rate * crossfadeDuration) / 2 * 2)
        let crossfadeHalf = crossfadeCount / 2

        for (index, segment) in segments.enumerated() {
            // 무음 없이 바로 이어지는지(직전/직후 세그먼트와 실질적으로 맞닿아 있는지) — 부동소수점
            // 반올림으로 한두 샘플 어긋날 수 있어 crossfadeHalf 이내면 "이어짐"으로 본다.
            let previous = index > 0 ? segments[index - 1] : nil
            let next = index < segments.count - 1 ? segments[index + 1] : nil
            let leadsFromPrevious = previous.map { segment.start - $0.end <= crossfadeHalf } ?? false
            let leadsToNext = next.map { $0.start - segment.end <= crossfadeHalf } ?? false

            // 크로스페이드는 경계 양쪽으로 절반씩 파고들어야(자기 몸통 일부 + 확장분) 이웃 세그먼트의
            // 크로스페이드 구간과 정확히 같은 절대 위치([경계-half, 경계+half])에서 겹친다 — 그래야
            // "이전 음의 1→0 램프"와 "다음 음의 0→1 램프"가 같은 지점에서 더해져 합이 1로 일정하다.
            let extStart = max(0, segment.start - (leadsFromPrevious ? crossfadeHalf : 0))
            let extEnd = min(bufferLength, segment.end + (leadsToNext ? crossfadeHalf : 0))
            guard extStart < extEnd else { continue }

            var tone = ToneSynthesizer.synthesize(frequency: segment.frequency, sampleCount: extEnd - extStart, sampleRate: rate)

            // 리딩/트레일링 램프가 서로 겹치면(음이 아주 짧아서 크로스페이드 구간 두 개를 합친
            // 것보다 짧은 경우) 같은 샘플이 두 램프에 곱해져 음 한가운데가 순간적으로 짜부라지는
            // 아티팩트가 생긴다(122절, "지지직" 제보의 원인으로 추정) — 리딩을 절대 tone.count의
            // 절반을 넘지 않게 먼저 정하고, 트레일링은 남은 몫에서만 가져가 절대 겹치지 않게 한다.
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
        let frequency: Double
    }

    /// 화음이 없는 스텝(쉼표, 온음계 밖 음)은 건너뛰어서 실제로 소리가 나는 구간만 남긴다.
    private static func voicedSegments(melodySteps: [MelodyStep], bufferLength: Int, voice: Voice, rate: Double) -> [Segment] {
        melodySteps.compactMap { step -> Segment? in
            guard let onset = step.onsetTime, let duration = step.duration, duration > 0,
                  let frequency = frequency(for: voice, step: step) else { return nil }
            let start = max(0, min(bufferLength, Int(onset * rate)))
            let end = max(0, min(bufferLength, Int((onset + duration) * rate)))
            guard start < end else { return nil }
            return Segment(start: start, end: end, frequency: frequency)
        }
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
