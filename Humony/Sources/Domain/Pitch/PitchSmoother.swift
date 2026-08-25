import Foundation

/// 프레임마다 튀는 피치 값을 지수이동평균(EMA)으로 눌러서 부드럽게 만든다.
/// 사람 목소리는 비브라토·발성 초반 불안정 때문에 프레임(약 46ms) 단위로 몇십 cent씩
/// 순간적으로 흔들리는데, 이걸 그대로 화면에 보여주면 "지금 맞는 음을 내고 있는지"
/// 판단하기 어려울 만큼 지저분하게 떨린다 (PRD 부록 B에서 이미 예상했던 보완책).
final class PitchSmoother {

    private var smoothedMIDINote: Double?

    // 0~1 사이. 클수록 최근 값에 더 민감(반응은 빠르지만 덜 부드러움),
    // 작을수록 더 부드럽지만 실제 음이 바뀔 때 따라오는 게 늦어진다.
    // 0.3 정도면 자연스러운 비브라토(초당 5~7회 흔들림)는 상당히 눌러주면서도
    // 다음 음으로 넘어가는 진짜 변화에는 200ms 안팎으로 따라붙는다.
    private let smoothingFactor = 0.3

    /// 주파수(Hz)가 아니라 MIDI 노트(로그 스케일)에서 평균을 낸다 — 피치는 로그적으로
    /// 지각되므로, Hz를 그대로 평균 내면 저음/고음에서 스무딩 정도가 서로 달라지는 왜곡이 생긴다.
    func smooth(frequency: Double) -> Double {
        let midiNote = NoteNameConverter.exactMIDINote(forFrequency: frequency)

        let updated: Double
        if let previous = smoothedMIDINote {
            updated = previous + smoothingFactor * (midiNote - previous)
        } else {
            updated = midiNote
        }
        smoothedMIDINote = updated

        return NoteNameConverter.frequency(forMIDINote: updated)
    }

    /// 새 세션/새 채점을 시작할 때 이전 값이 섞이지 않도록 초기화한다.
    func reset() {
        smoothedMIDINote = nil
    }
}
