import Foundation
import SwiftData

/// 채점 시도 하나(3도 또는 5도를 한동안 따라 부른 것)가 끝날 때마다 저장되는 기록.
/// 프레임 단위 원시 점수가 아니라 PracticeSummary.Aggregate로 압축한 결과만 저장한다 —
/// 세션 종료 후 "정확도 요약 + 자주 벗어난 화음 유형"을 보여주는 데는 이 정도 요약이면 충분하고,
/// 프레임마다(초당 20회 이상) 다 저장하면 금방 기기 저장공간을 낭비하게 된다.
@Model
final class PracticeAttempt {
    var date: Date

    // ChordGenerator.Interval을 SwiftData에 직접 저장하는 대신 문자열로 남긴다 —
    // 모델 스키마를 열거형 케이스 이름에 종속시키지 않기 위한 최소한의 격리.
    var intervalRawValue: String

    var targetNoteName: String
    var sampleCount: Int
    var onPitchRatio: Double
    var averageAbsCentsOffset: Double

    init(
        date: Date,
        intervalRawValue: String,
        targetNoteName: String,
        sampleCount: Int,
        onPitchRatio: Double,
        averageAbsCentsOffset: Double
    ) {
        self.date = date
        self.intervalRawValue = intervalRawValue
        self.targetNoteName = targetNoteName
        self.sampleCount = sampleCount
        self.onPitchRatio = onPitchRatio
        self.averageAbsCentsOffset = averageAbsCentsOffset
    }
}
