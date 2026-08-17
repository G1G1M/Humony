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

    /// - Parameter durations: 각 음의 실제 길이(초). 순서(멜로디 스텝 순서)를 그대로 유지해서
    ///   같은 인덱스의 결과를 돌려준다.
    static func quantize(durations: [Double]) -> [QuantizedNote] {
        guard !durations.isEmpty else { return [] }

        // 중앙값을 "1박"으로 삼는다 — 평균은 유난히 길게 끈 음 하나에 쉽게 휘둘리지만,
        // 중앙값은 "이 녹음에서 가장 흔한 길이"를 더 안정적으로 대표한다.
        let sorted = durations.sorted()
        let median = sorted[sorted.count / 2]
        let unit = max(median, 0.05) // 0으로 나누기 방지용 최소값

        return durations.map { duration in
            let ratio = duration / unit
            switch ratio {
            case ..<0.75:
                return QuantizedNote(vexFlowDuration: "8", beats: 0.5)
            case 0.75..<1.25:
                return QuantizedNote(vexFlowDuration: "q", beats: 1.0)
            case 1.25..<1.75:
                return QuantizedNote(vexFlowDuration: "qd", beats: 1.5)
            default:
                return QuantizedNote(vexFlowDuration: "h", beats: 2.0)
            }
        }
    }

    /// 누적 박이 4박(4/4박자 한 마디)을 넘을 때마다 마디를 끊어서, "이 마디엔 음 몇 개"를
    /// 순서대로 반환한다 — 모든 성부(멜로디/베이스/3도/5도)가 같은 타이밍 데이터(`MelodyStep`)를
    /// 공유하므로, 이 하나의 마디 구성을 전 성부에 그대로 적용하면 화면에서 성부끼리 같은
    /// 순간의 음이 세로로 정확히 맞춰진다(쉼표로 빈 자리를 채우는 것과 짝을 이룸).
    static func measureBreaks(notes: [QuantizedNote]) -> [Int] {
        var breaks: [Int] = []
        var currentCount = 0
        var currentBeats = 0.0

        for note in notes {
            currentCount += 1
            currentBeats += note.beats
            if currentBeats >= 4.0 {
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
