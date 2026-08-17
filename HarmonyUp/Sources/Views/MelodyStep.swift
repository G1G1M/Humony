import Foundation

/// 확정된 멜로디 음 하나와, 그 음 위에 쌓은 3성부(베이스/3도/5도) — 빠른 녹음으로 부른
/// 멜로디 전체를 순서대로 쌓은 데이터. 화면에 목록으로 보여주던 카드는 지금 단계에선
/// 필요 없어 없앴지만(다음 단계인 악보 렌더링까지는 이 데이터 자체가 그대로 필요해서
/// `PracticeView.applyQuickRecordResult`는 계속 이 배열을 채운다), 그 표시용 View
/// (`MelodyStepRow`)만 제거하고 데이터 모델은 남겨뒀다.
struct MelodyStep: Identifiable {
    let id = UUID()
    var noteName: String
    var midiNote: Int      // 옥타브까지 포함한 실제 MIDI 노트 — 수정 시 같은 옥타브 안에서 pitch class만 바꾸는 데 쓴다.
    // 성부(Interval)별 음이름 — 온음계 밖 음이면 nil(화음을 정의할 수 없음). 화면 표시 전용.
    var harmonyVoices: [ChordGenerator.Interval: String]?
    // harmonyVoices의 원본 데이터(실제 주파수 포함) — 채점/재생이 이 값을 그대로 읽어 쓴다.
    // Viterbi 기반 화음(ChordGenerator.harmonizeSequence)은 문맥(앞뒤 노트)을 보고 코드를
    // 고르므로, 스텝 하나만 떼어 다시 계산할 수 없다 — 배치로 한 번에 계산한 결과를 그대로
    // 들고 있어야 한다(docs/CONCEPTS.md 51절).
    var harmony: [ChordGenerator.HarmonyNote]? = nil
    // 빠른 녹음(RecordingAnalyzer) 경로에서만 채워진다 — 녹음 시작 기준 시작 시각/길이(초).
    var onsetTime: Double? = nil
    var duration: Double? = nil
}

extension MelodyStep {
    /// `ChordGenerator.HarmonyNote` 배열(베이스/3도/5도)을 [성부: 음이름] 딕셔너리로
    /// 변환한다 — `RecordingAnalyzer`/`PracticeView` 양쪽에서 같은 변환을 반복하지 않도록
    /// 한 곳에 모았다.
    static func harmonyVoices(from harmony: [ChordGenerator.HarmonyNote]?) -> [ChordGenerator.Interval: String]? {
        guard let harmony else { return nil }
        return Dictionary(uniqueKeysWithValues: harmony.map { note in
            (note.interval, NoteNameConverter.convert(frequency: note.frequency)?.noteName ?? "?")
        })
    }
}
