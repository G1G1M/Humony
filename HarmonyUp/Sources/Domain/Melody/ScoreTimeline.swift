import Foundation

/// 멜로디 스텝을 **악보에 그릴 순서대로의 이벤트 목록**(음표 + 쉼표)으로 바꾼다.
///
/// **왜 필요한가(149절)**: 지금까지 음표 길이를 "그 음을 부른 시간"(`MelodyStep.duration`)으로
/// 정했다. 그런데 박은 139절부터 **음 사이 간격(IOI)**에서 찾는다 — 기준이 서로 어긋나 있었다.
/// 스타카토로 끊거나 숨을 쉬면 그 시간이 어느 음표에도 안 들어가서, 마디에 담긴 총 시간이 실제
/// 노래보다 짧아진다. 표기 길이를 간격으로 잡고 남는 무음을 쉼표로 그리면 그 어긋남이 사라진다.
///
/// **이 타입이 인덱스의 기준이기도 하다**: `render.js`의 `setActiveStep(index)`는 그려진 음표
/// 배열을 그대로 인덱싱한다 — 쉼표도 한 자리를 차지하므로, 재생 위치 하이라이트도 스텝 인덱스가
/// 아니라 **이벤트 인덱스**로 말해야 한다. 악보 페이로드와 하이라이트가 같은 배열을 보게 해서
/// 두 인덱스 공간이 어긋날 여지를 없앴다.
enum ScoreTimeline {

    enum Event: Equatable {
        /// - Parameter stepIndex: **원본 `steps` 배열** 기준 인덱스. 성부별 화음을 되짚을 때 쓴다
        ///   (`onsetTime`이 없어 건너뛴 스텝이 있어도 원본 인덱스를 그대로 유지한다).
        case note(stepIndex: Int, start: Double, displayDuration: Double)
        case rest(start: Double, duration: Double)

        var start: Double {
            switch self {
            case .note(_, let start, _): return start
            case .rest(let start, _): return start
            }
        }

        var duration: Double {
            switch self {
            case .note(_, _, let duration): return duration
            case .rest(_, let duration): return duration
            }
        }
    }

    /// 이보다 짧은 틈은 쉼표로 그리지 않고 앞 음표 길이에 흡수한다(레가토로 본다).
    ///
    /// `MelodySegmenter.Configuration.minimumNoteDuration`과 같은 값을 쓴다 — 그보다 짧은 구간은
    /// 애초에 "진짜 음"으로 확정되지도 않는 길이라, 쉼표로 그려봤자 `RhythmQuantizer`가 표기할 수
    /// 있는 가장 짧은 음표(8분음표)에도 못 미쳐 격자만 어지럽힌다.
    static let defaultMinimumRestDuration: Double = 0.18

    /// - Parameter steps: 부른 순서대로의 멜로디 스텝. `onsetTime`이 없는 스텝은 리듬을 알 수 없어
    ///   악보에 못 그리므로 건너뛴다(기존 `VexFlowScorePayload.build`와 같은 규칙).
    static func events(from steps: [MelodyStep], minimumRestDuration: Double = defaultMinimumRestDuration) -> [Event] {
        let drawable = steps.enumerated().compactMap { index, step -> (stepIndex: Int, onset: Double, duration: Double)? in
            guard let onset = step.onsetTime else { return nil }
            return (index, onset, step.duration ?? 0.3)
        }
        guard !drawable.isEmpty else { return [] }

        var events: [Event] = []
        for (position, current) in drawable.enumerated() {
            guard position < drawable.count - 1 else {
                // 마지막 음은 다음 onset이 없으니 자기 발성 길이를 그대로 쓴다.
                events.append(.note(stepIndex: current.stepIndex, start: current.onset, displayDuration: current.duration))
                continue
            }

            let interval = drawable[position + 1].onset - current.onset
            let silence = interval - current.duration

            if silence >= minimumRestDuration {
                // 부른 만큼만 음표로 그리고, 남는 무음을 쉼표로 뗀다 — 둘의 합은 여전히 간격이다.
                events.append(.note(stepIndex: current.stepIndex, start: current.onset, displayDuration: current.duration))
                events.append(.rest(start: current.onset + current.duration, duration: silence))
            } else {
                // 틈이 없거나 무시할 만큼 짧다 — 간격 전체를 음표 길이로 삼는다.
                events.append(.note(stepIndex: current.stepIndex, start: current.onset, displayDuration: interval))
            }
        }
        return events
    }

    /// 재생 위치에 해당하는 **이벤트 인덱스**. 쉼표 구간이거나 노래 밖이면 nil(아무것도 강조 안 함).
    ///
    /// 뷰가 아니라 여기 두는 이유: 이건 순수 계산이고 유닛테스트로 고정할 수 있다 —
    /// `CLAUDE.md` 코딩 컨벤션("View의 `@State`에 묶인 메서드 안에 조합 로직을 두지 말 것").
    static func activeEventIndex(at time: Double, events: [Event]) -> Int? {
        for (index, event) in events.enumerated() {
            guard case .note = event else { continue }
            if time >= event.start, time < event.start + event.duration {
                return index
            }
        }
        return nil
    }
}
