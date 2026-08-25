import Foundation

/// "부른 대로 / 교정 후"를 두 줄로 나란히 그리는 악보 페이로드 (158절).
///
/// 악보를 붙였을 때 **무엇이 어떻게 바뀌었는지 눈으로 확인하고 넘어가는 관문**에 쓴다.
/// 숫자 요약("29음 일치, 2음 누락")만으로는 어느 음이 어떻게 고쳐졌는지 알 수 없다.
///
/// **핵심 불변식: 두 줄의 음 개수가 같아야 한다.** 교정은 음을 버릴 수 있어서(악보에 없는 짧은
/// 떨림) 그냥 이어 붙이면 뒤가 밀려 엉뚱한 음끼리 위아래로 놓인다 — 155절의 `MelodyAligner`로
/// 자리를 맞추고 빈 자리는 쉼표로 채운다. 교정에 쓴 것과 **같은 정렬**이라 화면에 보이는 짝이
/// 실제로 교정이 본 짝과 일치한다.
enum ScoreComparisonPayload {

    /// 비교 화면에서는 모든 음을 같은 길이로 그린다.
    ///
    /// 리듬은 여기서 정보가 아니다 — 교정은 **음높이만** 바꾸고 타이밍은 부른 그대로 두므로
    /// (155절) 두 줄의 리듬은 언제나 같다. 길이를 실제대로 그리면 화면만 복잡해지고, 정작
    /// 봐야 할 "어느 음이 달라졌나"가 묻힌다.
    private static let uniformDuration = "q"

    /// 4분음표 넷이 한 마디(4/4). 리듬을 균일하게 그리므로 마디도 균일하다.
    private static let notesPerMeasure = 4

    /// `HarmonyPracticeScorer`·`MelodyScoreCorrector`와 같은 값 — 한 옥타브 넘게 떨어지면
    /// 짝짓지 않는다.
    private static let gapPenaltyCents = 600.0

    static func build(beforeMIDINotes before: [Int], afterMIDINotes after: [Int]) -> VexFlowScorePayload.Payload {
        guard !before.isEmpty || !after.isEmpty else { return VexFlowScorePayload.empty }

        let pairs = MelodyAligner.align(
            targets: after.map { Double($0) * 100 },      // 반음 = 100cent
            sung: before.map { Double($0) * 100 },
            gapPenalty: gapPenaltyCents
        )

        var beforeRow: [Int?] = []
        var afterRow: [Int?] = []
        for pair in pairs {
            beforeRow.append(pair.sungIndex.map { before[$0] })
            afterRow.append(pair.targetIndex.map { after[$0] })
        }

        // 두 줄이 같은 음자리표를 써야 위아래를 그대로 견줄 수 있다.
        let clef = VexFlowScorePayload.clef(forMIDINotes: (beforeRow + afterRow).compactMap { $0 })

        let measureBreaks = Array(stride(from: notesPerMeasure, to: beforeRow.count, by: notesPerMeasure))
        return VexFlowScorePayload.Payload(
            voices: [voice(beforeRow, clef: clef), voice(afterRow, clef: clef)],
            measureBreaks: measureBreaks
        )
    }

    static func json(beforeMIDINotes before: [Int], afterMIDINotes after: [Int]) -> String {
        let payload = build(beforeMIDINotes: before, afterMIDINotes: after)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"voices\":[],\"measureBreaks\":[]}"
        }
        return json
    }

    private static func voice(_ midiNotes: [Int?], clef: String) -> VexFlowScorePayload.Payload.Voice {
        let notes = midiNotes.map { midiNote -> VexFlowScorePayload.Payload.Note in
            guard let midiNote else {
                return VexFlowScorePayload.Payload.Note(key: nil, sharp: false, duration: uniformDuration)
            }
            let (key, sharp) = VexFlowScorePayload.vexFlowKey(forMIDINote: midiNote)
            return VexFlowScorePayload.Payload.Note(key: key, sharp: sharp, duration: uniformDuration)
        }
        return VexFlowScorePayload.Payload.Voice(clef: clef, notes: notes)
    }
}
