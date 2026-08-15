import Foundation

/// 사용자가 부른 음이 목표음(target)과 얼마나 가까운지 채점한다.
/// NoteNameConverter의 centsOffset은 "가장 가까운 평균율 음"과의 편차인 반면,
/// 이건 임의의 목표 주파수(예: 화음의 3도 음) 하나와의 편차를 잰다는 점이 다르다.
enum PitchScorer {

    struct Score {
        let centsOffset: Double  // 목표음 대비 편차(cent). 양수=목표보다 높게, 음수=낮게 부름.
        let isOnPitch: Bool      // 허용 오차(onPitchToleranceCents) 이내인지
    }

    // 반음(100 cent)의 1/3 정도. 보컬 트레이닝 앱들이 흔히 쓰는 관용치를 참고한 시작값 —
    // 실제 사용자 테스트를 거쳐 조정 필요.
    static let onPitchToleranceCents = 35.0

    static func score(sungFrequency: Double, targetFrequency: Double) -> Score? {
        guard sungFrequency > 0, targetFrequency > 0 else { return nil }

        let cents = 1200.0 * log2(sungFrequency / targetFrequency)
        return Score(centsOffset: cents, isOnPitch: abs(cents) <= onPitchToleranceCents)
    }
}
