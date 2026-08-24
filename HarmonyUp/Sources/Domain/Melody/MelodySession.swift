import Foundation

/// 마이크에서 매 프레임 들어오는 감지 결과를 누적해서, 지금까지 부른 멜로디를 바탕으로
/// 조성을 판별하고 마지막으로 부른 음에 대한 화음을 제안한다.
/// AudioCapture와 마찬가지로 상태(지금까지 잡은 음들)를 갖는 I/O 인접 컴포넌트이고,
/// 실제 판단 로직(KeyDetector, ChordGenerator)은 그대로 순수 함수에 위임한다 —
/// 이 클래스는 "프레임 단위 결과를 순수 함수가 원하는 입력 형태로 누적/변환"하는 접착 역할만 한다.
final class MelodySession {

    struct RecordedNote {
        let pitchClass: Int
        // 코드 진행(ChordGenerator.harmonizeSequence)이 화음의 실제 옥타브를 배치하려면
        // 음이름(pitchClass)뿐 아니라 실제 MIDI 노트(옥타브 포함)가 필요하다.
        let midiNote: Int
        let duration: Double
    }

    // 이전엔 pitch class별 누적 길이(12칸 배열)만 들고 있었는데, 그러면 "몇 번째로 잡은 음이
    // 잘못됐으니 그것만 고쳐줘" 같은 개별 수정이 불가능하다. 잡은 음을 순서대로 배열에 남겨두면
    // KeyDetector에 넘길 때는 그대로 합산되고(같은 pitch class가 여러 개 있어도 KeyDetector가
    // 알아서 더함), 특정 인덱스만 골라 고치는 것도 가능해진다.
    private var notes: [RecordedNote] = []
    private(set) var lastNote: AudioCapture.DetectionResult?

    /// AudioCapture의 매 프레임 콜백 결과를 그대로 넘기면 된다.
    /// nil(무음/VAD로 걸러진 프레임)은 조성 판단에 영향을 주지 않도록 무시한다.
    func record(_ result: AudioCapture.DetectionResult?) {
        guard let result else { return }
        let midiNote = Int(NoteNameConverter.exactMIDINote(forFrequency: result.frequency).rounded())
        notes.append(RecordedNote(pitchClass: result.pitchClass, midiNote: midiNote, duration: result.frameDuration))
        lastNote = result
    }

    /// 실시간 검출이 틀렸을 때(예: 옥타브 안에서 반음 오검출) 사용자가 그 음만 골라 고칠 수 있게 한다.
    /// 조성 판별에 쓰이는 누적치를 갱신하고, 고친 게 마지막 음이었다면 화음 생성 기준(lastNote)도 같이 바꾼다.
    func correctNote(at index: Int, to corrected: AudioCapture.DetectionResult) {
        guard notes.indices.contains(index) else { return }
        let midiNote = Int(NoteNameConverter.exactMIDINote(forFrequency: corrected.frequency).rounded())
        notes[index] = RecordedNote(pitchClass: corrected.pitchClass, midiNote: midiNote, duration: notes[index].duration)

        if index == notes.count - 1 {
            lastNote = corrected
        }
    }

    func reset() {
        notes = []
        lastNote = nil
    }

    /// 지금까지 누적된 pitch-class 분포로 판별한 조성. 아직 부른 음이 없으면 nil.
    var detectedKey: KeyDetector.DetectedKey? {
        let weighted = notes.map { KeyDetector.WeightedNote(pitchClass: $0.pitchClass, duration: $0.duration) }
        return KeyDetector.detectKey(notes: weighted)
    }

    /// `suggestedHarmony`/`suggestedHarmonyBaseFrequency`가 공유하는 계산 — 코드를 두 번
    /// 안 돌리려고 한 곳에 모았다.
    private func harmonizedSequence() -> (notes: [RecordedNote], sequence: [[ChordGenerator.HarmonyNote]?])? {
        guard let key = detectedKey, !notes.isEmpty else { return nil }
        let sequence = ChordGenerator.harmonizeSequence(melodyNotes: notes.map { ($0.midiNote, $0.duration) }, key: key)
        return (notes, sequence)
    }

    /// 마지막으로 부른 음(정확히는, 뒤에서부터 훑어 온음계 안이라 화음이 나온 가장 최근 음) 위에
    /// 현재 조성 기준 3도/5도 화음을 제안한다. 노트가 하나도 없거나 조성이 아직 불명확하면 nil.
    ///
    /// `ChordGenerator.harmonizeSequence`는 Viterbi로 문맥(앞뒤 노트)을 보고 코드를 고르므로,
    /// 마지막 음 하나만 떼어 계산할 수 없다 — 지금까지 누적된 노트 전체로 다시 돌리고 마지막
    /// 결과만 취한다. 녹음 하나에 노트가 많아야 수십 개라 매번 다시 돌려도 성능 문제는 없다.
    ///
    /// 예전엔 정말로 `sequence.last`(마지막 음 그 자체)만 봤는데, "빠른 녹음"으로 노래 전체를
    /// 한꺼번에 분석하는 지금 방식에서는 하필 녹음이 온음계 밖 경과음(예: 자연단조 스케일에
    /// 없는 음)으로 끝나면 그 사실 하나 때문에 "내 목소리로 화음"/채점 카드 전체가 통째로 안
    /// 보이는 문제가 실기기에서 확인됐다 — 뒤에서부터 훑어 화음이 있는 가장 최근 음을 쓰도록
    /// 완화했다(실시간으로 한 음씩 들어오던 예전 캡처 방식이면 "지금 막 지나가는 경과음이라
    /// 화음을 내지 말라"는 의도가 유효했지만, 녹음 전체를 다 듣고 나서 보여주는 지금 흐름에서는
    /// 굳이 마지막 한 음에 그렇게까지 엄격할 이유가 없다).
    var suggestedHarmony: [ChordGenerator.HarmonyNote]? {
        guard let result = harmonizedSequence() else { return nil }
        return result.sequence.last(where: { $0 != nil }) ?? nil
    }

    /// `suggestedHarmony`가 실제로 기준 삼은 멜로디 음의 이론적 주파수(마지막 음이 온음계
    /// 밖이라 그보다 앞선 음을 대신 썼다면, 그 앞선 음 기준). `PracticeView.pitchRatio`가
    /// `lastNote`(진짜 마지막 음)를 그대로 분모로 쓰면, 화음은 다른 음 기준으로 나왔는데
    /// 비율은 엉뚱한 음 기준으로 나뉘어 실제 화성 관계와 안 맞는 비율이 나올 수 있다 — 항상
    /// 이 값을 같이 써서 "화음이 계산된 그 음"과 "비율 나누는 기준"을 일치시킨다.
    var suggestedHarmonyBaseFrequency: Double? {
        guard let result = harmonizedSequence(),
              let index = result.sequence.lastIndex(where: { $0 != nil }) else { return nil }
        return NoteNameConverter.frequency(forMIDINote: result.notes[index].midiNote)
    }
}
