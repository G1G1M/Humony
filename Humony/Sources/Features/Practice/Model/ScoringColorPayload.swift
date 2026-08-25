import Foundation

/// 채점 결과를 **악보 음표의 색**으로 옮기는 순수 함수(159절).
///
/// 예전엔 채점 결과가 음마다 한 줄씩(`목표음 → 부른음 ±cent`) 모노스페이스 텍스트로 나왔다.
/// 바로 위에 악보가 그려져 있는데도 "세 번째 줄이 틀렸다"를 읽고 눈으로 악보에서 그 음을 다시
/// 찾아야 했다 — 그 왕복을 없애고 틀린 음표 자체를 칠한다.
///
/// **이 타입이 존재하는 이유는 인덱스 공간이 세 개이기 때문이다.**
/// 1. **채점 인덱스** — 목표 성부의 음 순서(`HarmonyPracticeScorer.targetFrequencies`가 뽑는
///    것: 그 성부의 화음이 붙은 스텝만, `onsetTime`은 안 본다)
/// 2. **악보 스텝 인덱스** — `ScoreTimeline` 이벤트 순서. **쉼표가 한 자리를 차지하고**,
///    `onsetTime`이 없는 스텝은 아예 빠진다
/// 3. **악보 행 인덱스** — 실제로 그려진 성부의 순서. 음이 하나도 없는 성부는 행 자체가 빠져서
///    `VexFlowScorePayload.voiceOrder`의 위치와 다를 수 있다
///
/// 세 공간이 각각 다른 규칙으로 자리를 빼먹기 때문에, 한쪽 인덱스를 다른 쪽에 그대로 쓰면
/// 조용히 엉뚱한 음표가 칠해진다 — 149·158절에 정확히 같은 종류(정렬 안 한 두 배열을 이어붙임)로
/// 두 번 데였다. 그래서 계산을 뷰에 두지 않고 여기 모아 테스트로 박아뒀다
/// (`ScoringColorPayloadTests`).
enum ScoringColorPayload {

    /// **왜 시맨틱 색이 아니라 hex인가**: 이 색은 `WKWebView` 안 SVG 음표에 그대로 들어간다.
    /// 악보는 다크모드와 무관하게 항상 흰 종이인 게 관례라(68절) 웹뷰 배경을 흰색으로 고정해뒀고,
    /// 그 위에 얹는 색이라 시스템 시맨틱 색(`Theme.pitchGood` 등)을 쓸 수가 없다 — 값이 필요하다.
    /// 라이트 모드 기준의 시스템 색 값을 그대로 옮겨 적어서 앱의 다른 화면과 같은 색으로 보이게 한다.
    static let onPitchColor = "#34C759"  // systemGreen — 허용 오차 안
    /// 벗어난 음은 앱의 다른 곳에서 쓰는 주황(`Theme.warning`)이 아니라 빨강이다 —
    /// `render.js`의 재생 하이라이트(`ACTIVE_NOTE_COLOR`)가 이미 주황이라, 주황을 쓰면
    /// "지금 소리 나는 음"과 "틀린 음"을 구별할 수 없다.
    static let offPitchColor = "#FF3B30"  // systemRed
    /// 안 부른 음은 색으로 지적하기보다 **흐리게** 둔다 — 틀린 것과 아예 없는 것은 다르다.
    static let missedColor = "#B8B8BD"

    struct Entry: Encodable, Equatable {
        /// 악보 행 인덱스(위에서부터 0).
        let voice: Int
        /// 악보 스텝 인덱스(`ScoreTimeline` 이벤트 순서, 쉼표 포함).
        let step: Int
        let color: String
    }

    static func color(for step: HarmonyPracticeScorer.StepResult) -> String {
        if step.sungMIDINote == nil { return missedColor }
        return step.isOnPitch ? onPitchColor : offPitchColor
    }

    /// 채점 결과를 악보 위 어느 음표에 어떤 색으로 칠할지로 옮긴다.
    ///
    /// - Returns: 칠할 자리가 없으면 빈 배열. 특히 **채점 결과 개수와 목표 개수가 안 맞으면
    ///   아무것도 칠하지 않는다** — 그건 전제(채점 결과가 목표 순서를 그대로 따른다)가 깨진
    ///   상황이라, 앞에서부터 짝지어 붙이면 조용히 한 칸씩 밀린 색이 화면에 남는다.
    static func entries(
        steps: [MelodyStep],
        interval: ChordGenerator.Interval,
        result: HarmonyPracticeScorer.Result
    ) -> [Entry] {
        let events = ScoreTimeline.events(from: steps)
        guard let voiceRow = VexFlowScorePayload.drawnVoices(steps: steps, events: events)
            .firstIndex(where: { $0.interval == interval }) else { return [] }

        // 원본 스텝 인덱스 -> 악보 스텝 인덱스. 이벤트가 원본 인덱스를 그대로 들고 있어서
        // (`ScoreTimeline.Event.note(stepIndex:)`) 쉼표와 건너뛴 스텝을 여기서 전부 흡수한다.
        var scoreIndexByStep: [Int: Int] = [:]
        for (scoreIndex, event) in events.enumerated() {
            guard case .note(let stepIndex, _, _) = event else { continue }
            scoreIndexByStep[stepIndex] = scoreIndex
        }

        // 채점 목표가 된 스텝을 채점과 **똑같은 규칙**으로 다시 뽑는다
        // (`HarmonyPracticeScorer.targetFrequencies` + `score`의 `filter { $0 > 0 }`).
        // 규칙이 갈라지면 개수가 어긋나므로, 두 곳을 나란히 두고 같이 고쳐야 한다.
        let scoredStepIndices = steps.enumerated().compactMap { index, step -> Int? in
            guard let frequency = step.harmony?.first(where: { $0.interval == interval })?.frequency,
                  frequency > 0 else { return nil }
            return index
        }
        guard scoredStepIndices.count == result.steps.count else { return [] }

        return zip(result.steps, scoredStepIndices).compactMap { stepResult, stepIndex in
            // 악보에 안 그려진 스텝(onsetTime이 없어 이벤트가 만들어지지 않은 자리)은 칠할
            // 음표가 없다 — 조용히 건너뛴다. 뒤의 짝은 원본 인덱스로 잡으므로 밀리지 않는다.
            guard let scoreIndex = scoreIndexByStep[stepIndex] else { return nil }
            return Entry(voice: voiceRow, step: scoreIndex, color: color(for: stepResult))
        }
    }

    /// `render.js`의 `window.setStepColors(entries)`에 그대로 넘길 JSON 배열.
    static func json(
        steps: [MelodyStep],
        interval: ChordGenerator.Interval,
        result: HarmonyPracticeScorer.Result
    ) -> String {
        let entries = entries(steps: steps, interval: interval, result: result)
        guard !entries.isEmpty,
              let data = try? JSONEncoder().encode(entries),
              let json = String(data: data, encoding: .utf8) else { return emptyJSON }
        return json
    }

    /// 칠할 것이 없다는 뜻 — `setStepColors([])`는 이미 칠해진 색을 지우기도 한다.
    static let emptyJSON = "[]"
}
