import Foundation

/// 부른 음을 악보에 맞춰 교정한다 — 순수 함수 (155절).
///
/// **무엇을 고치고 무엇을 안 고치는가**가 이 타입의 전부다.
///
/// - 고친다: 짝지어진 음의 **음높이**를 악보 값으로. 채보가 반음 흔들려 적어둔 값이 화음
///   비율의 분모로 쓰이면서(153절) 그 구간 화음만 반음 어긋나던 문제가 여기서 사라진다.
/// - 안 고친다: **타이밍**(온셋·길이). 악보의 박자가 아니라 실제로 부른 리듬이 화음 타이밍의
///   기준이다 — 무반주로 부르는 앱이라 템포를 강제할 수 없다.
/// - 만들지 않는다: **누락된 음**. 안 부른 걸 악보에 그리면 거짓말이고, 그 자리에 화음까지
///   붙으면 부르지 않은 소리가 들린다.
enum MelodyScoreCorrector {

    struct Result: Equatable {
        let notes: [MelodySegmenter.SegmentedNote]
        /// 악보 음과 짝지어진 개수.
        let matchedCount: Int
        /// 악보엔 있는데 안 부른 개수.
        let missedCount: Int
        /// 악보에 없는데 부른 개수(짧아서 버린 것 포함).
        let extraCount: Int
        /// 실제로 음높이가 바뀐 개수 — 짝지어졌어도 한도를 넘으면 안 바꾼다.
        let snappedCount: Int
    }

    /// 짝지어도 되는 최대 차이(반음). 첫 값이고 실기기 로그로 조정한다.
    ///
    /// 2반음인 이유: 채보가 틀리는 방식은 대부분 **반음 흔들림**(149·152절)이고, 온음까지
    /// 열어두면 경과음을 이웃 음으로 끌어당기는 정도까지는 잡힌다. 그보다 크게 어긋났다면
    /// 정렬이 잘못 짝지었을 가능성이 더 크므로 건드리지 않는 편이 안전하다.
    static let defaultMaximumSnapSemitones = 2

    /// 악보에 없는 음을 "떨림·군더더기"로 보고 버리는 길이 기준(초).
    ///
    /// 153절 `VoiceHarmonyTrackBuilder.mergeBriefSegments`와 같은 값이다 — 그쪽은 소리에서
    /// 짧은 구간을 앞 구간에 흡수시켰고, 여기서는 채보에서 아예 없앤다. 실측(44초 녹음의 최종
    /// 70음 중 30음이 0.35초 이하)에서 고른 값이다.
    static let defaultBriefExtraDuration = 0.28

    /// 한 옥타브 넘게 동떨어진 음은 짝짓지 않는다(누락+추가 한 쌍 = 1200cent = 한 옥타브).
    /// `HarmonyPracticeScorer`와 같은 근거·같은 값이다.
    private static let gapPenaltyCents = 600.0

    /// - Parameters:
    ///   - sung: 채보가 잘라낸 음들(시간순).
    ///   - reference: 악보의 음(MIDI). **조옮김이 이미 적용된 값**이어야 한다 —
    ///     얼마나 옮겨 불렀는지는 `TranspositionEstimator`가 앞에서 정한다.
    static func correct(sung: [MelodySegmenter.SegmentedNote],
                        reference: [Int],
                        maximumSnapSemitones: Int = defaultMaximumSnapSemitones,
                        briefExtraDuration: Double = defaultBriefExtraDuration) -> Result {
        // 악보가 없으면 부른 그대로 — 악보 없는 흐름이 막히면 안 된다.
        guard !reference.isEmpty, !sung.isEmpty else {
            return Result(notes: sung, matchedCount: 0, missedCount: reference.count,
                          extraCount: sung.isEmpty ? 0 : sung.count, snappedCount: 0)
        }

        let pairs = MelodyAligner.align(
            targets: reference.map { Double($0) * 100 },       // 반음 = 100cent
            sung: sung.map { Double($0.midiNote) * 100 },
            gapPenalty: gapPenaltyCents
        )

        var notes: [MelodySegmenter.SegmentedNote] = []
        var matchedCount = 0
        var missedCount = 0
        var extraCount = 0
        var snappedCount = 0

        for pair in pairs {
            switch (pair.targetIndex, pair.sungIndex) {
            case let (targetIndex?, sungIndex?):
                matchedCount += 1
                let note = sung[sungIndex]
                let target = reference[targetIndex]

                guard abs(target - note.midiNote) <= maximumSnapSemitones else {
                    // 한도를 넘으면 그대로 둔다 — 정렬이 잘못 짝지었을 때 엉뚱한 음으로
                    // 끌려가는 걸 막는다(149절 회귀와 같은 종류의 위험).
                    notes.append(note)
                    continue
                }

                if target != note.midiNote { snappedCount += 1 }
                notes.append(MelodySegmenter.SegmentedNote(
                    midiNote: target,
                    onsetTime: note.onsetTime,
                    duration: note.duration,
                    averageConfidence: note.averageConfidence
                ))

            case (_?, nil):
                missedCount += 1

            case let (nil, sungIndex?):
                extraCount += 1
                let note = sung[sungIndex]
                // 짧으면 떨림·군더더기로 보고 버리고, 길면 남긴다 — 즉흥으로 넣었거나 악보가
                // 그 부분을 안 담고 있을 수 있다. 부른 것을 지우는 건 잡음이 확실할 때만이다.
                if note.duration >= briefExtraDuration { notes.append(note) }

            case (nil, nil):
                continue // align이 만들지 않는 조합
            }
        }

        return Result(notes: notes, matchedCount: matchedCount, missedCount: missedCount,
                      extraCount: extraCount, snappedCount: snappedCount)
    }
}
