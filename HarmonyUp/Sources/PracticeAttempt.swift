import Foundation
import SwiftData

/// 채점 시도 하나 — 한 세션(`PracticeSession`)의 어느 성부를 한 소절 따라 부른 결과.
///
/// 프레임 단위 원시 점수를 저장하지 않는 원칙은 그대로다(초당 20회 이상이면 금방 저장공간
/// 낭비다). 다만 136절 채점 재설계로 저장할 내용이 달라졌다 — 예전엔 "허용오차 안이었던 프레임
/// 비율"이었고, 이제는 **목표음 하나하나에 대한 정렬 결과**를 요약한 것이다:
/// 정확도, 평균 편차(부호 있는 것과 없는 것), 안 부른 음, 목표에 없는데 부른 음.
///
/// 여기에 **틀린 음의 정체**까지 남긴다(`offTargetMIDINotes` / `offTargetCents` /
/// `missedMIDINotes`) — 기록 탭에서 "F#4에서 자주 낮게 부름(평균 −38cent)"처럼 다음에 무엇을
/// 연습할지 알려주려면 성부 단위 평균만으로는 부족하고 음 단위 데이터가 필요하다. 소절 하나에
/// 음이 많아야 수십 개라 이 정도는 저장해도 부담이 없다.
@Model
final class PracticeAttempt {
    var date: Date

    // ChordGenerator.Interval을 SwiftData에 직접 저장하는 대신 문자열로 남긴다 —
    // 모델 스키마를 열거형 케이스 이름에 종속시키지 않기 위한 최소한의 격리.
    var intervalRawValue: String

    /// 허용 오차 안에 든 목표음의 비율(0~1). 안 부른 음도 분모에 포함된다.
    var onPitchRatio: Double
    /// 짝지어진 음들의 평균 편차 크기(cent, 부호 무시) — "얼마나 벗어났나".
    var averageAbsCentsOffset: Double
    /// 부호를 살린 평균 편차 — "높게/낮게 부르는 편"인지. 절대값 평균만으로는 방향이 안 보인다.
    var averageSignedCentsOffset: Double

    var targetNoteCount: Int
    var missedCount: Int
    var extraCount: Int

    /// 허용 오차를 벗어난 목표음들과 그때의 편차(cent) — 두 배열은 같은 길이이고 같은 순서다.
    /// 부호를 살려 저장해서 "이 음에서는 낮게 부른다"까지 알 수 있게 한다.
    var offTargetMIDINotes: [Int]
    var offTargetCents: [Double]
    /// 아예 부르지 않은 목표음들.
    var missedMIDINotes: [Int]

    var session: PracticeSession?

    init(
        date: Date,
        intervalRawValue: String,
        onPitchRatio: Double,
        averageAbsCentsOffset: Double,
        averageSignedCentsOffset: Double,
        targetNoteCount: Int,
        missedCount: Int,
        extraCount: Int,
        offTargetMIDINotes: [Int],
        offTargetCents: [Double],
        missedMIDINotes: [Int]
    ) {
        self.date = date
        self.intervalRawValue = intervalRawValue
        self.onPitchRatio = onPitchRatio
        self.averageAbsCentsOffset = averageAbsCentsOffset
        self.averageSignedCentsOffset = averageSignedCentsOffset
        self.targetNoteCount = targetNoteCount
        self.missedCount = missedCount
        self.extraCount = extraCount
        self.offTargetMIDINotes = offTargetMIDINotes
        self.offTargetCents = offTargetCents
        self.missedMIDINotes = missedMIDINotes
    }
}

extension PracticeAttempt {

    /// 채점 결과(`HarmonyPracticeScorer.Result`)를 저장 형태로 옮긴다 — 뷰가 필드를 하나하나
    /// 채우지 않도록 변환을 한곳에 모았다.
    convenience init(result: HarmonyPracticeScorer.Result, interval: ChordGenerator.Interval, date: Date) {
        // 틀린 음만 골라 남긴다 — 정확히 부른 음까지 다 저장할 필요는 없고(정확도로 이미 요약됨),
        // "어디서 틀리는지"에 답하려면 벗어난 음의 정체가 필요하다.
        let offTarget = result.steps.filter { !$0.isOnPitch && $0.sungMIDINote != nil }
        let missed = result.steps.filter { $0.sungMIDINote == nil }

        self.init(
            date: date,
            intervalRawValue: interval.storageKey,
            onPitchRatio: result.onPitchRatio,
            averageAbsCentsOffset: result.averageAbsCentsOffset,
            averageSignedCentsOffset: result.averageSignedCentsOffset,
            targetNoteCount: result.steps.count,
            missedCount: result.missedCount,
            extraCount: result.extraCount,
            offTargetMIDINotes: offTarget.map(\.targetMIDINote),
            offTargetCents: offTarget.compactMap(\.centsOffset),
            missedMIDINotes: missed.map(\.targetMIDINote)
        )
    }

    var interval: ChordGenerator.Interval? {
        ChordGenerator.Interval.from(storageKey: intervalRawValue)
    }
}
