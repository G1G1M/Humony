import Foundation

/// `HarmonyTrackBuilder`(WORLD 기반 목소리 피치시프트)의 대안 — 사용자 목소리를 옮기는 대신,
/// 스텝마다 목표 주파수를 `ToneSynthesizer`로 직접 합성해서 화음 트랙을 만든다.
///
/// **왜 이게 다시 필요해졌나(2026-08-20)**: 92절(WSOLA)부터 WORLD 보코더 도입까지 목소리
/// 피치시프트 품질을 계속 다듬어왔지만, "화음이 멜로디랑 따로 들린다"는 실기기 제보가
/// 사라지지 않았다. 사용자가 "화음을 처음 넣었을 때(TonePlayer로 합성음 재생, 커밋
/// `c757f3a`)가 제일 정확하게 들렸다"며 그때로 되돌려달라고 요청 — 다만 그 시점의 코드
/// 구조(단음 캡처 모드, `ContentView` 단일 파일)는 지금과 완전히 달라 파일 단위로 되돌릴 수
/// 없어서, 지금 구조(`HarmonyTrackBuilder`와 같은 스텝 순회+길이 보존 계약) 위에서 **화음의
/// 소리 생성 방식만** 그때의 파형(`ToneSynthesizer`, `TonePlayer`와 동일한 합성식)으로
/// 바꿔 재현한 것이 이 타입이다. 멜로디(원음)는 그대로 두고 베이스/3도/5도만 영향을 받는다.
///
/// 목소리가 아니라 합성음이라 `PitchShifter`(WORLD)도 `VoiceDoubler`(목소리 두께감용
/// 더블링)도 필요 없다 — 그래서 `HarmonyTrackBuilder`보다 파라미터가 더 단순하다.
enum SynthesizedHarmonyTrackBuilder {

    /// - Parameters:
    ///   - melodySteps: 녹음 전체의 멜로디 스텝 시퀀스(음이름/MIDI/화음/시작시각/길이).
    ///   - bufferLength: 결과 트랙이 맞춰야 할 길이(원본 녹음 샘플 개수) — 목소리 내용 자체는
    ///     쓰지 않고 길이만 필요하므로 `[Float]` 전체가 아니라 `Int`만 받는다.
    ///   - interval: 만들 성부(베이스/3도/5도).
    ///   - startStepIndex: 이 지점부터 시작(악보 탭 탐색용). `nil`이면 처음부터.
    ///   - startTime: `startStepIndex`에 대응하는 시작 시각(초) — 그 이전 구간은 결과에서 제외된다.
    ///   - rate: 샘플레이트.
    ///   - segmentFadeDuration: 스텝 경계 클릭 방지용 페이드 길이(초).
    /// - Returns: `bufferLength`와 정확히 같은 길이의 배열 — 화음이 없는 구간(쉼표,
    ///   `startTime` 이전 구간)은 무음(0)으로 채워진다. `HarmonyTrackBuilder.build`와 동일한
    ///   길이 보존 계약을 그대로 따른다.
    static func build(
        melodySteps: [MelodyStep],
        bufferLength: Int,
        interval: ChordGenerator.Interval,
        startStepIndex: Int?,
        startTime: Double,
        rate: Double,
        segmentFadeDuration: Double
    ) -> [Float] {
        let startIndex = startStepIndex ?? 0
        guard melodySteps.indices.contains(startIndex) else { return [] }

        let segmentFadeCount = max(1, Int(rate * segmentFadeDuration))
        let bufferEnd = bufferLength
        var output: [Float] = []
        var cursor = max(0, min(bufferEnd, Int(startTime * rate)))

        for i in startIndex..<melodySteps.count {
            let step = melodySteps[i]
            guard let onset = step.onsetTime, let duration = step.duration, duration > 0 else { continue }
            let segStart = max(0, Int(onset * rate))
            let segEnd = min(bufferEnd, Int((onset + duration) * rate))
            guard segStart < segEnd else { continue }

            if segStart > cursor {
                output.append(contentsOf: [Float](repeating: 0, count: segStart - cursor))
            }

            if let target = step.harmony?.first(where: { $0.interval == interval }) {
                let tone = ToneSynthesizer.synthesize(frequency: target.frequency, sampleCount: segEnd - segStart, sampleRate: rate)
                output.append(contentsOf: AudioGain.applyFadeInOut(tone, fadeSampleCount: min(segmentFadeCount, tone.count / 2)))
            } else {
                output.append(contentsOf: [Float](repeating: 0, count: segEnd - segStart))
            }
            cursor = segEnd
        }

        if cursor < bufferEnd {
            output.append(contentsOf: [Float](repeating: 0, count: bufferEnd - cursor))
        }
        return output
    }
}
