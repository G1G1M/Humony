import Foundation

/// 판별된 조성(KeyDetector.DetectedKey)을 기준으로, 멜로디 노트 시퀀스 전체에 코드 진행을
/// 붙여서 3성부(베이스/이너보이스1(3도)/이너보이스2(5도))를 생성한다 — 아카펠라 4인 편성
/// (리드 멜로디 + 이 3성부)을 흉내낸다.
///
/// "지금 재생 중인 반주 코드"를 별도로 입력받지 않는다 — 이 앱은 반주 없이 목소리 하나만
/// 녹음/분석하는 구조라 코드 데이터가 저절로 생기는 소스가 없고, "멜로디를 녹음하면 나머지
/// 화성이 다 자동으로 나와야 한다"는 요구사항 때문이다.
///
/// **화성 모델(v1로 회귀, 101절)**: v2(51절)에서는 조성의 다이어토닉 코드 7개(I~vii°) 중
/// 그 구간에 가장 어울리는 코드를 HMM+Viterbi로 골라 배정했다 — 화음이 멜로디 음 여러 개에
/// 걸쳐 유지될 수 있고(경과음 처리), "화성 리듬이 멜로디 리듬보다 느린" 실제 편곡 관행을
/// 흉내낸 것이었다. 하지만 이건 곧 "화음이 매 멜로디 음마다 같이 움직이지 않고 문맥에 따라
/// 몇 음에 걸쳐 붙잡고 있을 수 있다"는 뜻이기도 해서, 실기기 청취에서 반복적으로 나온
/// "화음 박자가 안 맞는다/밀린다" 피드백의 실제 원인이 이 설계 자체였을 가능성이 크다 —
/// DSP 쪽(더블링/포먼트/페이드/재생 스케줄링)을 여러 차례 손봐도 해소되지 않던 이유이기도
/// 하다. 사용자가 "화음을 멜로디 음 하나하나에 맞게"를 명시적으로 요청해 v1(멜로디 음 자신이
/// 그 순간 화음의 근음, 음마다 새로 계산)으로 되돌린다 — Viterbi/HMM(전이 점수, 감정 점수,
/// 토널 기능) 관련 코드는 이제 안 쓰여서 함께 제거했다.
enum ChordGenerator {

    enum Interval: Hashable, CaseIterable {
        case bass
        case third
        case fifth

        /// 화면에 보여줄 짧은 한글 라벨 — 여러 화면(멜로디 스텝 목록, 재생 버튼, 채점 패널)에서
        /// 같은 표기를 반복하지 않도록 한 곳에 모았다.
        var koreanLabel: String {
            switch self {
            case .bass: return "베이스"
            case .third: return "3도"
            case .fifth: return "5도"
            }
        }

        // SwiftData(PracticeAttempt)에 저장할 때 쓰는 문자열 키 — enum 케이스를 직접 저장하지
        // 않고 문자열로 격리해서, 모델 스키마가 열거형 케이스 이름/순서에 종속되지 않게 한다.
        var storageKey: String {
            switch self {
            case .bass: return "bass"
            case .third: return "third"
            case .fifth: return "fifth"
            }
        }

        /// 여러 성부를 동시에 재생할 때 좌우로 벌리는 위치(-1=완전 왼쪽 ~ 1=완전 오른쪽).
        /// 사람 귀는 같은 방향에서 겹쳐 나는 소리보다 다른 방향에서 나는 소리를 훨씬 잘
        /// 구분한다(docs/CONCEPTS.md 52절) — 리드 멜로디는 중앙(0.0, `PracticeView`에서 별도
        /// 지정), 베이스는 저음이라 방향감이 잘 안 느껴져서 중앙에 살짝만 치우치고, 3도/5도는
        /// 좌우로 크게 갈라 성부 분리감을 키운다(Phase 8 Task 2, docs/CONCEPTS.md 77절).
        var pan: Float {
            switch self {
            case .bass: return -0.25
            case .third: return 0.45
            case .fifth: return -0.55
            }
        }

        /// 포먼트(스펙트럼 포락선, 성도 길이가 만드는 음색) 이동 비율 — `PitchShifterWorld.shift`의
        /// `formantRatio`로 그대로 전달된다(Phase 8 Task 1, docs/CONCEPTS.md 77절). 베이스를
        /// 아래로(성도가 긴 실제 저음처럼), 3도/5도는 위로(맑은 두성처럼) 옮겨 다른 성역의
        /// 사람이 부르는 느낌을 낸다 — 지금은 전부 같은 목소리를 피치만 옮긴 소리라 "한 사람이
        /// 여러 번 겹쳐 부른" 느낌이 남는다는 128절 피드백에 대응.
        ///
        /// **128절, 다시 켬**: 95절엔 0.85/1.15로 껐었다("기계음 같고 싱크 안 맞음") — 그 시절
        /// 원인으로 지목됐던 재생 타이밍/크로스페이드 문제는 121·125~128절에서 이미 구조적으로
        /// 고쳤으므로 다시 시도해볼 조건이 됐다고 판단. 다만 한 번에 크게 틀지 않고 95절
        /// 값(0.85/1.15)보다 살짝 보수적인 값으로 시작 — 실기기 청취로 더 키우거나 줄일 시작값.
        var formantRatio: Double {
            switch self {
            case .bass: return 0.9
            case .third: return 1.1
            case .fifth: return 1.1
            }
        }

        /// 성부별 상대 음량 배율 — 원래는 바버샵 보이싱 관행(근음·5도를 두드러지게, 3도는
        /// 배경에 머물게)을 흉내내 3도만 0.85로 살짝 낮췄었다. 실기기로 여러 가지를 청취
        /// 검증하는 과정에서 사용자가 "4개 성부가 다 같은 크기로 나오게 해달라 — 직접 들으며
        /// 조정하겠다"고 요청 — 믹스 밸런스를 코드가 미리 정해두지 않고, 전부 1.0(균등)에서
        /// 시작해 사용자가 직접 청감으로 조정할 수 있게 중립값으로 되돌렸다.
        var gain: Float {
            1.0
        }

        static func from(storageKey: String) -> Interval? {
            allCases.first { $0.storageKey == storageKey }
        }
    }

    struct HarmonyNote {
        let interval: Interval
        let midiNote: Int
        let frequency: Double
        let pitchClass: Int
    }

    // 온음계를 이루는 반음 간격. 장조(Ionian)와 자연 단조(Aeolian) — 두 경우 모두
    // 으뜸음에서부터 7개 음이 어떤 반음 간격으로 놓이는지를 나타낸다.
    private static let majorScaleIntervals = [0, 2, 4, 5, 7, 9, 11]
    private static let minorScaleIntervals = [0, 2, 3, 5, 7, 8, 10]

    /// 다이어토닉 코드 후보 하나(스케일 디그리 0~6 중 하나 위에 3도씩 쌓은 트라이어드) —
    /// `chordCandidates(scale:)`가 반환하는 배열의 인덱스 자체가 스케일 디그리와 같다.
    private struct ChordCandidate {
        let rootPitchClass: Int
        let thirdPitchClass: Int
        let fifthPitchClass: Int
    }

    /// - Parameters:
    ///   - melodyNotes: 멜로디 노트 시퀀스 전체(순서대로) — 각 노트의 실제 MIDI 노트와 길이(초).
    ///     v1 모델은 노트마다 독립적으로 화음을 계산하므로(문맥 의존 없음) 시퀀스 전체를 넘길
    ///     필요는 없지만, `harmonizedTrack` 등 호출부와의 인터페이스를 유지하기 위해 시그니처는
    ///     그대로 둔다.
    ///   - key: KeyDetector가 판별한 조성
    /// - Returns: `melodyNotes`와 인덱스가 정렬된 배열. 각 원소는 `[베이스, 이너보이스1(3도),
    ///   이너보이스2(5도)]` — **그 멜로디 음 자신을 근음으로 삼은** 트라이어드다(101절, v1
    ///   모델). 그 노트가 판별된 조성의 온음계에 속하지 않으면(예: 반음계 경과음) 새 화음을
    ///   계산하지 않고 **직전 유효 화음을 그대로 이어서 반환**한다 — 실제 백킹보컬/아카펠라
    ///   관행이 이렇다(화음 성부는 리드가 짧게 스쳐가는 경과음까지 따라 움직이지 않고, 화음을
    ///   그대로 붙잡고 있다가 다음 음에서만 움직인다). 시퀀스 맨 앞부터 온음계 밖 음이 나와
    ///   붙잡을 직전 화음이 아직 없으면(비교 대상 없음) 그때만 nil을 유지한다.
    static func harmonizeSequence(melodyNotes: [(midiNote: Int, duration: Double)], key: KeyDetector.DetectedKey) -> [[HarmonyNote]?] {
        guard !melodyNotes.isEmpty else { return [] }

        let scale = diatonicScale(tonic: key.tonicPitchClass, mode: key.mode)
        let candidates = chordCandidates(scale: scale)

        var lastValidHarmony: [HarmonyNote]?
        var results: [[HarmonyNote]?] = []
        results.reserveCapacity(melodyNotes.count)
        for note in melodyNotes {
            let pitchClass = note.midiNote.mod(12)
            // 이 멜로디 음 자신을 근음으로 갖는 다이어토닉 트라이어드를 찾는다 — 온음계 안
            // 음이면 스케일 어딘가에 정확히 일치하는 디그리가 항상 있다.
            guard let degree = scale.firstIndex(of: pitchClass) else {
                results.append(lastValidHarmony)
                continue
            }
            let notes = buildHarmonyNotes(candidate: candidates[degree], melodyMIDINote: note.midiNote)
            lastValidHarmony = notes
            results.append(notes)
        }
        return results
    }

    private static func diatonicScale(tonic: Int, mode: KeyDetector.Mode) -> [Int] {
        let intervals = mode == .major ? majorScaleIntervals : minorScaleIntervals
        return intervals.map { (tonic + $0).mod(12) }
    }

    /// 스케일 디그리 0~6마다 그 위에 3도씩 쌓은 트라이어드(I, ii, iii, IV, V, vi, vii°) 7개를
    /// 만든다.
    private static func chordCandidates(scale: [Int]) -> [ChordCandidate] {
        (0..<7).map { degree in
            ChordCandidate(
                rootPitchClass: scale[degree],
                thirdPitchClass: scale[(degree + 2) % 7],
                fifthPitchClass: scale[(degree + 4) % 7]
            )
        }
    }

    private static func buildHarmonyNotes(candidate: ChordCandidate, melodyMIDINote: Int) -> [HarmonyNote] {
        let bass = bassNote(rootPitchClass: candidate.rootPitchClass, melodyMIDINote: melodyMIDINote)
        let third = innerVoiceNote(interval: .third, targetPitchClass: candidate.thirdPitchClass, bassMIDINote: bass.midiNote)
        let fifth = innerVoiceNote(interval: .fifth, targetPitchClass: candidate.fifthPitchClass, bassMIDINote: bass.midiNote)
        return [bass, third, fifth]
    }

    /// 3도/5도가 항상 베이스와 멜로디 "사이"에 들어갈 여유를 보장하는 최소 간격(반음).
    /// 다이어토닉 스케일에서 5도는 근음 기준 최대 8반음 위까지 갈 수 있으므로(아래
    /// `innerVoiceNote` 문서 참고), 그보다 한 반음 더 넉넉하게 9로 잡으면 3도/5도가 절대
    /// 멜로디와 같거나 넘어갈 수 없다는 게 수학적으로 보장된다 — 옥타브를 오가며 자리를 찾는
    /// 루프 없이 한 번에 안전한 자리를 계산할 수 있다.
    private static let minimumBassToMelodyGap = 9

    /// 베이스 = 코드의 근음(더 이상 멜로디 자신의 음이름이 아닐 수 있다 — v1과의 핵심 차이)을,
    /// 멜로디보다 `minimumBassToMelodyGap` 반음 이상 아래인 자리 중 멜로디에 가장 가까운
    /// (= "대략 1옥타브 아래"에 가장 가까운) 옥타브에 놓는다.
    private static func bassNote(rootPitchClass: Int, melodyMIDINote: Int) -> HarmonyNote {
        let ceiling = melodyMIDINote - minimumBassToMelodyGap
        let base = ceiling - ceiling.mod(12)
        var midiNote = base + rootPitchClass
        if midiNote > ceiling {
            midiNote -= 12
        }
        return HarmonyNote(
            interval: .bass,
            midiNote: midiNote,
            frequency: NoteNameConverter.frequency(forMIDINote: midiNote),
            pitchClass: midiNote.mod(12)
        )
    }

    /// 3도/5도 이너보이스 — 베이스 바로 위 옥타브 밴드에서 목표 음이름(코드의 3도/5도)의
    /// 위치를 찾는다.
    ///
    /// 성부 교차가 나지 않는 이유(수학적으로 항상 성립): 온음계에서 근음 기준 3도는 항상
    /// 3~4반음, 5도는 항상 6~8반음 위다(장/단조 자연음계 어디서 시작해도 이 범위를 벗어나지
    /// 않는다) — 즉 "3도 거리 < 5도 거리 ≤ 8 < `minimumBassToMelodyGap`(9)"가 항상 성립해서,
    /// 베이스 < 3도 < 5도 < 멜로디 순서가 예전처럼 ">=멜로디면 옥타브 내리기" 같은 별도
    /// 방어 로직 없이도 자연히 유지된다.
    private static func innerVoiceNote(interval: Interval, targetPitchClass: Int, bassMIDINote: Int) -> HarmonyNote {
        let bassOctaveBase = bassMIDINote - bassMIDINote.mod(12)
        var targetMIDINote = bassOctaveBase + targetPitchClass

        // 목표 음이름의 원시 pitch class 값이 베이스보다 숫자가 작을 수 있다(예: 베이스=B(11),
        // 목표=D(2)) — 그러면 위 계산이 베이스보다 낮은 자리를 가리키므로 한 옥타브 올린다.
        if targetMIDINote <= bassMIDINote {
            targetMIDINote += 12
        }

        return HarmonyNote(
            interval: interval,
            midiNote: targetMIDINote,
            frequency: NoteNameConverter.frequency(forMIDINote: targetMIDINote),
            pitchClass: targetPitchClass
        )
    }
}
