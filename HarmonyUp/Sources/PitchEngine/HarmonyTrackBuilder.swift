import Foundation

/// `PracticeView+VoiceHarmony.harmonizedTrack`이 하던 "성부 하나(베이스/3도/5도)의 재생
/// 트랙을 멜로디 스텝 단위로 만드는" 로직을 순수 함수로 뽑아낸 것 — 그 메서드는 `PracticeView`의
/// `@State`(melodySteps/recentVoiceBuffer 등)에 묶여 있어서 유닛테스트가 불가능했다.
///
/// **왜 이 파일이 필요한가(106절 이후 교훈)**: 이 조합 로직(간격 처리, 여러 음 이어붙이기)을
/// 손댈 때마다(99·104·105절) 실제로 문제가 생겼는데, `PitchShifter`/`VoiceDoubler`/
/// `AudioGain`/`ChordGenerator` 같은 `PitchEngine/`의 다른 순수 함수들은 전부 자기 XCTest가
/// 있어서 한 번도 실패한 적이 없었다 — 깨진 건 항상 "이것들을 어떻게 조합하는지"였는데, 그
/// 조합 로직만 유일하게 테스트가 없어서 실기기에서 소리로만 문제가 드러났다. 이 타입은 그
/// 조합 로직을 `PitchEngine/`의 나머지와 같은 방식(순수 함수 + XCTest)으로 편입시킨다.
///
/// 이 파일을 다시 손댈 때 지킬 규칙: (1) 바꾸려는 불변식(주로 길이 보존)을 먼저
/// `HarmonyTrackBuilderTests`에 테스트로 써서 통과시킨 뒤 실기기로 넘어갈 것. (2) 여러 개념
/// (간격 처리+크로스페이드+더블링 등)을 한 번에 동시에 바꾸지 말 것 — 어느 변경이 무엇을
/// 고쳤는지/깼는지 추적하기 어려워진다. (3) 복잡한 해법보다 단순한 해법을 우선할 것 — 복잡도
/// 자체가 99·104·105절에서 새 버그의 원인이었다.
enum HarmonyTrackBuilder {

    /// - Parameters:
    ///   - melodySteps: 녹음 전체의 멜로디 스텝 시퀀스(음이름/MIDI/화음/시작시각/길이).
    ///   - recentVoiceBuffer: 원본 녹음 샘플 — 결과 트랙은 항상 이것과 같은 길이여야 한다
    ///     (재생 타이밍/재생헤드 매핑이 이 전제에 의존한다).
    ///   - interval: 만들 성부(베이스/3도/5도).
    ///   - startStepIndex: 이 지점부터 시작(악보 탭 탐색용). `nil`이면 처음부터.
    ///   - startTime: `startStepIndex`에 대응하는 시작 시각(초) — 그 이전 구간은 결과에서 제외된다.
    ///   - rate: 샘플레이트.
    ///   - segmentFadeDuration: 스텝 경계 클릭 방지용 페이드 길이(초).
    ///   - isVoiceDoublingEnabled: `VoiceDoubler`(지연+디튠 두께감)를 적용할지.
    /// - Returns: `recentVoiceBuffer`와 정확히 같은 길이의 배열 — 화음이 없는 구간(쉼표,
    ///   `startTime` 이전 구간)은 무음(0)으로 채워진다.
    static func build(
        melodySteps: [MelodyStep],
        recentVoiceBuffer: [Float],
        interval: ChordGenerator.Interval,
        startStepIndex: Int?,
        startTime: Double,
        rate: Double,
        segmentFadeDuration: Double,
        isVoiceDoublingEnabled: Bool
    ) -> [Float] {
        let startIndex = startStepIndex ?? 0
        guard melodySteps.indices.contains(startIndex) else { return [] }

        // 세그먼트 경계에서 나는 클릭음을 없애는 짧은 페이드 — 클릭 방지에 필요한 최소한만
        // 쓴다(너무 길면 매 음의 공격이 부드러워져 "화음이 박자보다 밀려 들린다"는 인상을 만든다).
        let segmentFadeCount = max(1, Int(rate * segmentFadeDuration))
        let bufferEnd = recentVoiceBuffer.count
        var output: [Float] = []
        var cursor = max(0, min(bufferEnd, Int(startTime * rate)))

        // 106절: 멜로디 스텝 하나하나를 완전히 독립적으로, 자기 자신의 시작 시각·길이 그대로만
        // 피치시프트해서 순서대로 이어붙인다 — 화음의 타이밍이 항상 멜로디 스텝과 정확히
        // 1:1로 대응해서, 스텝이 아무리 많아도(노래가 빨라도) 누적되어 어긋날 여지가
        // 구조적으로 없다. 예전엔(99·104·105절) 간격을 이어붙이거나 여러 스텝을 하나의 런으로
        // 묶어 한 번에 처리하는 방식이었는데, 그 조합 로직 자체에 트랙 길이를 미묘하게
        // 어긋나게 하는 버그가 있어서 "노래가 빠를수록(전환이 잦을수록) 화음이 밀린다"는
        // 실기기 제보로 이어졌다 — 사용자 요청으로 이 단순한 형태로 되돌렸다(git 히스토리에
        // 이전 버전이 남아있어 필요하면 다시 가져올 수 있다).
        for i in startIndex..<melodySteps.count {
            let step = melodySteps[i]
            guard let onset = step.onsetTime, let duration = step.duration, duration > 0 else { continue }
            let segStart = max(0, Int(onset * rate))
            let segEnd = min(bufferEnd, Int((onset + duration) * rate))
            guard segStart < segEnd else { continue }

            if segStart > cursor {
                output.append(contentsOf: [Float](repeating: 0, count: segStart - cursor))
            }

            let segment = Array(recentVoiceBuffer[segStart..<segEnd])
            if let target = step.harmony?.first(where: { $0.interval == interval }) {
                let ratio = target.frequency / NoteNameConverter.frequency(forMIDINote: step.midiNote)
                let shifted = PitchShifter.shift(samples: segment, pitchRatio: ratio, formantRatio: interval.formantRatio, sampleRate: rate)
                let doubled = isVoiceDoublingEnabled ? VoiceDoubler.apply(to: shifted, sampleRate: rate, interval: interval) : shifted
                output.append(contentsOf: AudioGain.applyFadeInOut(doubled, fadeSampleCount: min(segmentFadeCount, doubled.count / 2)))
            } else {
                output.append(contentsOf: [Float](repeating: 0, count: segment.count))
            }
            cursor = segEnd
        }

        if cursor < bufferEnd {
            output.append(contentsOf: [Float](repeating: 0, count: bufferEnd - cursor))
        }
        return output
    }
}
