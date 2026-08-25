import Foundation

/// 초 단위 실제 길이(`MelodyStep.duration`)를 오선보에서 쓰는 음표 종류(4분음표, 8분음표...)로
/// 바꾸는 순수 함수. 이 앱은 템포/박자를 검출하지 않아서 "몇 분음표"인지 절대적으로 알 수는
/// 없지만, **상대적인 길이 비교**는 가능하다 — 전체 음들의 중앙값 길이를 "1박(4분음표)"로
/// 삼고, 그보다 짧으면 8분음표, 길면 점4분음표/2분음표로 분류한다.
///
/// 왜 필요한가: VexFlow 오선보를 도입한 뒤에도 모든 음을 똑같은 4분음표로만 그렸더니
/// "너무 인위적으로 보인다"는 피드백을 받았다 — 실제 악보는 음표 모양 자체가 리듬(길고
/// 짧음)을 보여주는데, 전부 같은 모양이면 그 정보가 아예 없어서 "데이터를 기계적으로
/// 나열한 것"처럼 보인다(docs/CONCEPTS.md 59절). 정확한 박자 표기는 여전히 불가능하지만,
/// 최소한 "이 음은 길게, 저 음은 짧게 불렀다"는 상대적 리듬감은 음표 모양으로 표현할 수 있다.
enum RhythmQuantizer {
    struct QuantizedNote {
        /// VexFlow 음표 길이 코드 — "8"(8분음표)/"q"(4분음표)/"qd"(점4분음표)/"h"(2분음표).
        let vexFlowDuration: String
        /// 이 음표가 정확히 몇 박(4분음표=1.0 기준)을 차지하는지 — 마디를 나눌 때 누적해서 쓴다.
        let beats: Double
    }

    /// 추정한 템포를 실제로 쓰려면 이 정도 확신은 있어야 한다 — 무반주로 자유롭게 부르면 박이
    /// 아예 없을 수 있고, 그때 억지로 격자에 맞추면 악보가 오히려 더 이상해진다. 그런 경우엔
    /// 아래 중앙값 방식으로 폴백한다.
    ///
    /// 0.75인 근거: 사람이 부른 정도의 흔들림(간격이 ±6%씩 들쭉날쭉한 경우)에서도 확신이
    /// 0.9를 넘는 반면, 박이 없는 자유 리듬은 0.7 언저리에 머문다 — 그 사이를 가른다.
    static let minimumTempoConfidence = 0.75

    /// - Parameter durations: 각 음의 실제 길이(초). 순서(멜로디 스텝 순서)를 그대로 유지해서
    ///   같은 인덱스의 결과를 돌려준다.
    static func quantize(durations: [Double]) -> [QuantizedNote] {
        quantize(durations: durations, onsetTimes: nil)
    }

    /// 음이 시작한 시각까지 같이 주면 **실제 박을 추정해서**(`TempoEstimator`) 그 그리드로
    /// 분류한다(136절).
    ///
    /// **왜 중앙값만으로는 부족한가**: 중앙값은 "이 녹음에서 가장 흔한 길이"일 뿐 "1박"이 아니다.
    /// 8분음표가 지배적인 노래에서는 그 8분음표가 중앙값이 돼서 전부 4분음표로 표기되고, 정작
    /// 4분음표는 2분음표가 된다 — 상대적인 길고 짧음은 살지만 실제 리듬과는 어긋난다. 음이
    /// 시작한 간격에서 박을 찾아내면 그 어긋남이 사라진다.
    ///
    /// 박을 못 찾거나 확신이 낮으면(자유 리듬) 기존 중앙값 방식을 그대로 쓴다 — 없는 박을
    /// 지어내는 것보다 "상대적 길이"라도 정직하게 보여주는 편이 낫다.
    ///
    /// - Parameter onsetTimes: 각 음의 시작 시각(초). `MelodyStep.onsetTime`을 그대로 넘기면 된다.
    ///   nil이면 예전처럼 중앙값 기준으로만 분류한다.
    static func quantize(durations: [Double], onsetTimes: [Double]?) -> [QuantizedNote] {
        guard !durations.isEmpty else { return [] }

        if let onsetTimes,
           let estimate = TempoEstimator.estimate(onsetTimes: onsetTimes),
           estimate.confidence >= minimumTempoConfidence {
            return durations.map { classify(beats: estimate.beats(forDuration: $0)) }
        }

        // 폴백 — 중앙값을 "1박"으로 삼는다. 평균은 유난히 길게 끈 음 하나에 쉽게 휘둘리지만,
        // 중앙값은 "이 녹음에서 가장 흔한 길이"를 더 안정적으로 대표한다.
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let unit = max(median, 0.05) // 0으로 나누기 방지용 최소값

        return durations.map { classify(beats: $0 / unit) }
    }

    /// 박 수를 실제 음표 모양으로 스냅한다 — 두 경로(박 추정 / 중앙값 폴백)가 같은 경계를
    /// 쓰도록 한곳에 모았다. 표기할 수 있는 건 8분·4분·점4분·2분·점2분·온음표 여섯 가지다.
    ///
    /// **150절에 점2분·온음표가 추가됐다.** 그전엔 2분음표(2박)가 상한이라, 길게 끈 음이나 긴
    /// 쉼표가 전부 2박으로 잘려 그만큼의 시간이 악보에서 사라졌다 — 실기기 로그에서 1.34초
    /// (약 2.5박)짜리 무음이 실제로 나왔다. 149절에 `ScoreTimeline`이 "음표+쉼표 = 간격"으로
    /// 시간을 보존해도, 여기서 잘리면 그 보존이 무의미해진다.
    ///
    /// 경계는 전부 이웃한 두 값의 중간이다(0.75 / 1.25 / 1.75 / 2.5 / 3.5).
    /// **온음표(4박)가 상한인 이유**: 4/4 한 마디가 4박이라 그보다 긴 음표는 표기할 수 없고,
    /// 그런 값이 나오면 `measureBreaks`가 "한 음이 마디를 넘는다"는 처리할 수 없는 상태에 빠진다
    /// (그 함수의 무한 루프 안전장치가 "음 하나는 절대 4박을 안 넘는다"에 기대고 있다).
    private static func classify(beats: Double) -> QuantizedNote {
        switch beats {
        case ..<0.75:
            return QuantizedNote(vexFlowDuration: "8", beats: 0.5)
        case 0.75..<1.25:
            return QuantizedNote(vexFlowDuration: "q", beats: 1.0)
        case 1.25..<1.75:
            return QuantizedNote(vexFlowDuration: "qd", beats: 1.5)
        case 1.75..<2.5:
            return QuantizedNote(vexFlowDuration: "h", beats: 2.0)
        case 2.5..<3.5:
            return QuantizedNote(vexFlowDuration: "hd", beats: 3.0)
        default:
            return QuantizedNote(vexFlowDuration: "w", beats: 4.0)
        }
    }

    /// 한 마디에 담을 수 있는 박 수 — 악보를 4/4로 표기하고 있으므로(`render.js`의
    /// `addTimeSignature('4/4')`) 그 표기와 실제 내용이 어긋나지 않게 여기서도 4박을 쓴다.
    static let beatsPerMeasure = 4.0

    /// 마디를 4박(4/4박자 한 마디)씩 끊어서, "이 마디엔 음 몇 개"를 순서대로 반환한다 —
    /// 모든 성부(멜로디/베이스/3도/5도)가 같은 타이밍 데이터(`MelodyStep`)를 공유하므로,
    /// 이 하나의 마디 구성을 전 성부에 그대로 적용하면 화면에서 성부끼리 같은 순간의 음이
    /// 세로로 정확히 맞춰진다(쉼표로 빈 자리를 채우는 것과 짝을 이룸).
    ///
    /// **136절, 마디가 4박을 넘던 버그 수정**: 예전엔 음을 먼저 넣고 나서 "누적이 4박 이상이면
    /// 끊는다"였다 — 4분음표 3개(3박) 뒤에 2분음표(2박)가 오면 그 2분음표까지 같은 마디에
    /// 들어가 5박짜리 마디가 만들어졌다. 악보에는 4/4라고 써놓고 실제로는 5박이 든 마디를
    /// 그리고 있었던 것(`render.js`가 `setStrict(false)`로 VexFlow 검증을 꺼둬서 에러 없이
    /// 그려졌을 뿐이다). 이제는 음을 넣기 **전에** 그 음까지 넣으면 4박을 넘는지 먼저 보고,
    /// 넘으면 마디를 먼저 끊어서 그 음이 다음 마디의 첫 음이 되게 한다.
    ///
    /// 음 하나가 그 자체로 4박을 **넘는** 경우는 `classify`가 온음표(4박)를 상한으로 두므로
    /// 생기지 않는다 — 그래서 "빈 마디를 끊는" 무한 루프도 구조적으로 없다
    /// (`currentCount > 0` 가드가 그 안전장치를 겸한다). 정확히 4박인 온음표는 자기 마디를
    /// 통째로 차지하고 바로 끊긴다(150절에 온음표를 추가하며 이 전제를 다시 확인했다).
    static func measureBreaks(notes: [QuantizedNote]) -> [Int] {
        var breaks: [Int] = []
        var currentCount = 0
        var currentBeats = 0.0

        for note in notes {
            if currentCount > 0, currentBeats + note.beats > beatsPerMeasure {
                breaks.append(currentCount)
                currentCount = 0
                currentBeats = 0
            }

            currentCount += 1
            currentBeats += note.beats

            if currentBeats >= beatsPerMeasure {
                breaks.append(currentCount)
                currentCount = 0
                currentBeats = 0
            }
        }
        if currentCount > 0 {
            breaks.append(currentCount)
        }
        return breaks
    }
}
