import Foundation

/// 판별된 조성(KeyDetector.DetectedKey)을 기준으로, 멜로디 노트 시퀀스 전체에 코드 진행을
/// 붙여서 3성부(베이스/이너보이스1(3도)/이너보이스2(5도))를 생성한다 — 아카펠라 4인 편성
/// (리드 멜로디 + 이 3성부)을 흉내낸다.
///
/// "지금 재생 중인 반주 코드"를 별도로 입력받지 않는다 — 이 앱은 반주 없이 목소리 하나만
/// 녹음/분석하는 구조라 코드 데이터가 저절로 생기는 소스가 없고, "멜로디를 녹음하면 나머지
/// 화성이 다 자동으로 나와야 한다"는 요구사항 때문이다.
///
/// **화성 모델 v2(133절, HMM+Viterbi 재도입)**: v1(101절, "멜로디 음 자신이 그 순간 화음의
/// 근음")은 화음이 매 멜로디 음마다 같이 움직여서 사실상 병행진행에 가까웠다 — 실기기 청취에서
/// "화음이 고정된 느낌, 화음 진행 자체가 단순반복"으로 재확인됐다(133절). 101~102절 당시엔
/// "화음 박자가 안 맞는다"는 피드백으로 v2에서 v1으로 되돌렸었지만, 119절에서 이미 "그 원인이
/// 사실 v2 설계 자체가 아니라 크로스페이드 버그였을 가능성"을 진단해뒀고 그 버그는
/// 121·128~132절에서 전부 해결됐다 — 그래서 v2를 다시 들여왔다. 조성의 다이어토닉 코드
/// 7개(I~vii°) 중 그 구간에 가장 어울리는 코드를 HMM+Viterbi로 골라 배정한다 — 화음이 멜로디
/// 음 여러 개에 걸쳐 유지될 수 있고(경과음 처리), "화성 리듬이 멜로디 리듬보다 느린" 실제
/// 편곡 관행을 흉내낸다.
enum ChordGenerator {

    /// 화음 성부 하나 — **자리**(음높이 순서)를 가리킨다.
    ///
    /// 케이스 이름(`third`/`fifth`)은 원래 "화음의 3도/5도"라는 뜻이었지만, 146절에 보이스
    /// 리딩(전위 사용)이 들어가면서 그 의미가 사라졌다 — 이제 `.bass`/`.third`/`.fifth`는
    /// 각각 아랫소리/가운뎃소리/윗소리라는 **자리**이고, 그 자리가 어떤 화음음을 맡는지는
    /// 화음마다 달라진다. 케이스 이름을 그대로 두는 이유는 `storageKey`가 이미 저장된
    /// 기록(SwiftData)의 성부를 이 문자열로 찾기 때문이다 — 이름을 바꾸면 기존 기록이 성부를
    /// 잃는다. 사용자에게 보이는 이름은 `koreanLabel`이 자리 이름으로 돌려준다.
    enum Interval: Hashable, CaseIterable {
        case bass
        case third
        case fifth

        /// 화면에 보여줄 짧은 한글 라벨 — 여러 화면(멜로디 스텝 목록, 재생 버튼, 채점 패널)에서
        /// 같은 표기를 반복하지 않도록 한 곳에 모았다.
        ///
        /// **146절에 "3도/5도"에서 자리 이름으로 바뀌었다.** 보이스 리딩이 들어가면서 전위를
        /// 쓰게 되어, 같은 성부가 화음마다 다른 구성음(근음/3도/5도)을 맡는다 — "3도"라고
        /// 이름 붙은 성부가 실제로는 근음을 부르는 일이 생기므로 그 이름은 거짓이 된다.
        /// 자리 이름은 언제나 참이고(성부 순서는 불변식으로 보장된다), 화성 지식이 없는 첫
        /// 사용자에게도 "3도"보다 알아보기 쉽다.
        var koreanLabel: String {
            switch self {
            case .bass: return "아랫소리"
            case .third: return "가운뎃소리"
            case .fifth: return "윗소리"
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
        /// 고쳤으므로 다시 시도해볼 조건이 됐다고 판단. 0.9/1.1로 처음 시도했는데 실기기
        /// 청취에서 "오히려 더 이상하다"는 재확인 — 강도를 더 줄여 0.95/1.05로 낮췄다(더
        /// 이상하면 아예 1.0으로 되돌릴 후보).
        var formantRatio: Double {
            switch self {
            case .bass: return 0.95
            case .third: return 1.05
            case .fifth: return 1.05
            }
        }

        /// 성부별 미세 디튠(cent) — 145절 "휴머나이즈".
        ///
        /// **왜 일부러 음을 어긋나게 하나**: 지금 화음 성부는 WORLD 분석 **하나**에서 F0만
        /// 옮겨 재합성한 것이라(143절 구조), 세 성부의 비브라토·떨림이 샘플 단위로 완전히
        /// 동일하다. 사람 넷이 부르면 각자 몇 cent씩 어긋나고 그 미세한 차이가 맥놀이를 만들어
        /// "여러 명"으로 들리는데, 차이가 정확히 0이면 뇌는 한 사람의 배음으로 합쳐 듣는다
        /// (코러스 이펙터가 하는 일이 바로 이 어긋남을 인위적으로 만드는 것이다).
        ///
        /// 값은 ±10cent 안쪽으로 잡는다 — 그보다 크면 "화음이 틀렸다"로 들린다(반음=100cent).
        /// 방향도 성부마다 다르게 둬서 서로 상쇄되지 않게 한다.
        var detuneCents: Double {
            switch self {
            case .bass: return -5
            case .third: return 6
            case .fifth: return -3
            }
        }

        /// `detuneCents`를 주파수 배율로 바꾼 값(1200cent = 2배).
        var detuneRatio: Double { pow(2.0, detuneCents / 1200.0) }

        /// 성부별 발성 시작 지연(초) — 145절 "휴머나이즈".
        ///
        /// 실제 합창은 각자 숨 쉬는 타이밍이 달라 음 시작이 수십 ms씩 흩어진다. 지금은 한
        /// 녹음을 그대로 복제해 쓰므로 세 성부의 자음/모음 시작이 완벽히 같은 시각이라,
        /// 겹칠수록 "한 사람이 크게" 들린다. 40ms를 넘기면 어긋남이 아니라 박자 밀림으로
        /// 들리므로 그 안쪽에서 서로 다른 값을 준다.
        var onsetOffsetSeconds: Double {
            switch self {
            case .bass: return 0.018
            case .third: return 0.009
            case .fifth: return 0.026
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

        /// 화면에 성부를 나열할 때 쓰는 순서 — 오선보 관례대로 **높은 성부부터**.
        ///
        /// `allCases`(선언 순서: 베이스/3도/5도)를 화면마다 그대로 쓰다 보니 순서가 갈렸다 —
        /// 악보는 음높이 내림차순(멜로디/5도/3도/베이스)인데 조작부와 기록은 오름차순이라,
        /// "멜로디 바로 아래"가 한쪽에선 최저음이고 다른 쪽에선 두 번째 고음이었다(139절 이후
        /// UI 크리틱 지적). 사용자 결정으로 **악보 순서로 통일**하면서, 다시 갈리지 않도록
        /// 순서를 여기 한 곳에만 둔다.
        ///
        /// 이 순서가 실제 음높이와 항상 일치하는 근거: `innerVoiceNote`가 "베이스 < 3도 < 5도 <
        /// 멜로디"를 수학적으로 보장한다(온음계에서 근음 기준 3도는 3~4반음, 5도는 6~8반음 위이고
        /// 멜로디까지는 `minimumBassToMelodyGap`(9반음) 이상 벌어져 성부 교차가 불가능하다).
        static let displayOrder: [Interval] = [.fifth, .third, .bass]

        /// `displayOrder`에서의 자리 — 성부별 데이터를 화면 순서대로 정렬할 때 쓴다.
        var displayIndex: Int {
            Self.displayOrder.firstIndex(of: self) ?? Self.displayOrder.count
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

        func contains(pitchClass: Int) -> Bool {
            pitchClass == rootPitchClass || pitchClass == thirdPitchClass || pitchClass == fifthPitchClass
        }
    }

    /// 표준 3기능 화성학(Tonic/Subdominant/Dominant)의 단순화 매핑 — I/iii/vi=Tonic,
    /// ii/IV=Subdominant, V/vii°=Dominant(51절).
    private enum TonalFunction {
        case tonic, subdominant, dominant
    }

    private static let functionByDegree: [TonalFunction] = [.tonic, .subdominant, .tonic, .subdominant, .dominant, .tonic, .dominant]

    /// - Parameters:
    ///   - melodyNotes: 멜로디 노트 시퀀스 전체(순서대로) — 각 노트의 실제 MIDI 노트와 길이(초).
    ///     Viterbi가 앞뒤 노트의 문맥(길이 포함)을 보고 코드 진행을 고르므로, 노트 하나만
    ///     떼어 다시 계산할 수 없다 — 시퀀스 전체를 항상 통째로 넘겨야 한다.
    ///   - key: KeyDetector가 판별한 조성
    /// - Returns: `melodyNotes`와 인덱스가 정렬된 배열. 각 원소는 `[베이스, 이너보이스1(3도),
    ///   이너보이스2(5도)]` — 조성의 다이어토닉 코드 7개(I~vii°) 중 그 구간에 문맥상 가장
    ///   어울리는 코드를 HMM+Viterbi로 골라 배정한 트라이어드다(51·133절, v2 모델). 그 노트가
    ///   판별된 조성의 온음계에 속하지 않으면(예: 반음계 경과음) 새 화음을 계산하지 않고
    ///   **직전 유효 화음을 그대로 이어서 반환**한다 — 실제 백킹보컬/아카펠라 관행이 이렇다.
    ///   시퀀스 맨 앞부터 온음계 밖 음이 나와 붙잡을 직전 화음이 아직 없으면(비교 대상 없음)
    ///   그때만 nil을 유지한다.
    static func harmonizeSequence(melodyNotes: [(midiNote: Int, duration: Double)], key: KeyDetector.DetectedKey) -> [[HarmonyNote]?] {
        guard !melodyNotes.isEmpty else { return [] }

        let scale = diatonicScale(tonic: key.tonicPitchClass, mode: key.mode)
        let candidates = chordCandidates(scale: scale)
        let degrees = viterbiChordDegrees(melodyNotes: melodyNotes, scale: scale, candidates: candidates)

        var lastValidHarmony: [HarmonyNote]?
        // 온음계 밖 음(degree == nil)에서는 갱신하지 않는다 — 직전 화음을 그대로 이어받으므로
        // 코드가 바뀐 게 아니다.
        var previousDegree: Int?
        var results: [[HarmonyNote]?] = []
        results.reserveCapacity(melodyNotes.count)
        for (index, note) in melodyNotes.enumerated() {
            guard let degree = degrees[index] else {
                results.append(lastValidHarmony)
                continue
            }
            // 첫 화음은 기준이 될 직전 보이싱이 없으므로 근음 위치로 배치하고(레지스터를 여기서
            // 정한다), 코드가 바뀔 때만 가장 적게 움직이는 배치를 새로 고른다(146절).
            //
            // **코드가 그대로면 자리도 그대로 둔다(147절)**: 자리를 바꾸는 건 화성적으로 뭔가
            // 일어났다는 신호인데, 코드가 유지되는 동안 전위가 바뀌면 아무 일도 없는데 화음이
            // 발밑에서 움직이는 것처럼 들린다 — 실기기 청취에서 "부자연스럽게 화음이 들어간다"로
            // 나온 증상이고, 21음 프레이즈를 덤프해보니 실제로 4번 일어나고 있었다.
            let notes: [HarmonyNote]
            if let previous = lastValidHarmony, previousDegree == degree, heldVoicingFits(previous: previous, melodyMIDINote: note.midiNote) {
                notes = previous
            } else if let previous = lastValidHarmony {
                notes = voiceLedHarmonyNotes(candidate: candidates[degree], melodyMIDINote: note.midiNote, previous: previous)
            } else {
                notes = buildHarmonyNotes(candidate: candidates[degree], melodyMIDINote: note.midiNote)
            }
            previousDegree = degree
            lastValidHarmony = notes
            results.append(notes)
        }
        return results
    }

    /// 노트마다 어떤 코드 후보(디그리 0~6)를 배정할지 Viterbi로 정한다. 온음계 밖 음은 방출
    /// 점수를 모든 후보에 중립(0)으로 둬서 코드 흐름 자체는 끊기지 않게 하되(경과음이 지나가는
    /// 동안 화음이 안 바뀌도록 유도하는 전이 점수가 그대로 작동한다), 결과 배열에는 nil을 담아
    /// `harmonizeSequence`가 "온음계 밖 음은 새 화음 대신 직전 화음을 이어받는다" 계약을 그대로
    /// 지키게 한다.
    private static func viterbiChordDegrees(
        melodyNotes: [(midiNote: Int, duration: Double)],
        scale: [Int],
        candidates: [ChordCandidate]
    ) -> [Int?] {
        let isOnScale = melodyNotes.map { scale.contains($0.midiNote.mod(12)) }

        // dp[i][c] = 노트 0...i를 코드 c로 끝나게 배정했을 때의 최선 누적 점수.
        // backpointer[i][c] = 그 최선을 만든 직전 노트의 코드.
        var dp = [[Double]](repeating: [Double](repeating: 0, count: candidates.count), count: melodyNotes.count)
        var backpointer = [[Int]](repeating: [Int](repeating: 0, count: candidates.count), count: melodyNotes.count)

        for c in 0..<candidates.count {
            dp[0][c] = emissionScore(note: melodyNotes[0], candidate: candidates[c])
        }
        for i in 1..<melodyNotes.count {
            let emissions = candidates.map { emissionScore(note: melodyNotes[i], candidate: $0) }
            for c in 0..<candidates.count {
                var bestPrev = 0
                var bestScore = -Double.infinity
                for prevC in 0..<candidates.count {
                    let score = dp[i - 1][prevC] + transitionScore(from: prevC, to: c)
                    if score > bestScore {
                        bestScore = score
                        bestPrev = prevC
                    }
                }
                dp[i][c] = emissions[c] + bestScore
                backpointer[i][c] = bestPrev
            }
        }

        var bestFinal = 0
        var bestFinalScore = -Double.infinity
        for c in 0..<candidates.count where dp[melodyNotes.count - 1][c] > bestFinalScore {
            bestFinalScore = dp[melodyNotes.count - 1][c]
            bestFinal = c
        }

        var degreesReversed: [Int] = [bestFinal]
        var current = bestFinal
        for i in stride(from: melodyNotes.count - 1, to: 0, by: -1) {
            current = backpointer[i][current]
            degreesReversed.append(current)
        }
        let degrees = degreesReversed.reversed()

        return zip(degrees, isOnScale).map { degree, onScale in onScale ? degree : nil }
    }

    /// 멜로디 음 하나가 후보 코드의 구성음(근음/3도/5도)이면 높은 점수, 아니면 낮은 점수 —
    /// 길이로 가중해서(길수록 안 맞을 때 더 불리) 짧은 경과음은 코드 판단에 덜 관여하게 한다
    /// (51절, `KeyDetector`의 조성 판별 가중치와 같은 원리). 온음계 밖 음은 중립(0)으로 둬서
    /// 앞뒤 코드 흐름을 끊지 않는다.
    private static func emissionScore(note: (midiNote: Int, duration: Double), candidate: ChordCandidate) -> Double {
        let pitchClass = note.midiNote.mod(12)
        guard candidate.contains(pitchClass: pitchClass) else {
            return -1.0 * note.duration
        }
        return 2.0 * note.duration
    }

    /// 코드에서 코드로 넘어갈 때의 점수(51절) — 같은 코드를 유지하면 가장 큰 보너스(경과음이
    /// 지나가도 화음이 안 바뀌게 유도하는 이번 재도입의 핵심), 근음이 4도 위/아래로 움직이는
    /// "강한 진행"은 중간 보너스(circle-of-fifths 진행이 자연히 나오게 한다), 3도 관계는 약한
    /// 보너스, 2도 관계는 중립. 추가로 Dominant→Subdominant "역행"은 페널티, Dominant→Tonic
    /// "해결"은 보너스를 얹어 T→S→D→T 순환 원칙을 반영한다.
    private static func transitionScore(from prevDegree: Int, to degree: Int) -> Double {
        let diff = (degree - prevDegree + 7) % 7
        var score: Double
        switch diff {
        case 0: score = 3.0
        case 3, 4: score = 2.0
        case 2, 5: score = 1.0
        default: score = 0.0 // 1, 6 — 근음이 2도로 움직이는 가장 약한 진행
        }

        let prevFunction = functionByDegree[prevDegree]
        let function = functionByDegree[degree]
        if prevFunction == .dominant && function == .subdominant {
            score -= 1.0
        } else if prevFunction == .dominant && function == .tonic {
            score += 1.0
        }
        return score
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

    /// 화음 성부가 멜로디와 부딪히지 않도록 두는 최소 간격(반음) — 멜로디 바로 아래 반음에
    /// 화음음을 놓으면 맥놀이가 심해서 편곡에서 피한다. 온음(2반음)까지는 띄운다.
    private static let minimumMelodyClearance = 2

    /// 화음 맨 윗소리가 멜로디에서 이 이상 멀어지지 않게 하는 상한(반음).
    ///
    /// **왜 필요한가**: 보이스 리딩은 "직전에서 적게 움직이기"만 보기 때문에, 그것만 두면
    /// 멜로디가 한 옥타브를 올라가도 화음은 제자리에 머무는 게 항상 최소 비용이다 — 실제로
    /// 덤프해보니 멜로디가 C5까지 오르는 동안 화음이 C3에 남아 간격이 17반음까지 벌어졌다.
    /// 그러면 화음이 리드를 받쳐주는 게 아니라 저 아래 깔린 드론처럼 들린다. 아카펠라의 백킹
    /// 성부는 리드 바로 아래 한 옥타브 안쪽에 붙어 있으므로 그걸 상한으로 강제한다 — 멜로디가
    /// 그 밖으로 나가면 화음도 따라 올라갈 수밖에 없고, 그때 "어떻게 올라갈지"를 이동량이 정한다.
    private static let maximumMelodyToTopVoiceGap = 12

    /// 세 성부가 벌어질 수 있는 최대 폭(반음) — 화음을 닫힌 자리(close position)로 유지한다.
    /// 옥타브를 자유롭게 고르게 두면 베이스만 저 아래로 떨어져 화음이 텅 빈 것처럼 들린다.
    private static let maximumVoicingSpread = 12

    /// 코드가 유지되는 동안 직전 자리를 그대로 써도 되는지 — 멜로디를 침범하지 않으면 그대로 둔다.
    ///
    /// 자리를 바꾸는 건 화성적으로 뭔가 일어났다는 신호다. 코드가 유지되는 동안 전위가 바뀌면
    /// 아무 일도 없는데 화음이 발밑에서 움직이는 것처럼 들린다 — 실기기 청취에서 "부자연스럽게
    /// 화음이 들어간다"로 나온 증상이고, 21음 프레이즈를 덤프해보니 실제로 4번 일어나고 있었다.
    ///
    /// 멜로디가 위로 멀어지는 건 그냥 둔다(간격은 다음 코드 변화에서 정리된다). 반대로 멜로디가
    /// 화음 쪽으로 내려와 부딪히게 되면 그때는 어쩔 수 없이 옮겨야 하는데, 그때도 화음 전체를
    /// 한 옥타브 떨어뜨리는 것(세 성부 × 12반음)보다 최소 이동으로 다시 고르는 편이 훨씬 덜 튄다
    /// — 실측으로 총 이동량 36반음 대 12반음이었다.
    private static func heldVoicingFits(previous: [HarmonyNote], melodyMIDINote: Int) -> Bool {
        guard let top = previous.map(\.midiNote).max() else { return false }
        return top <= melodyMIDINote - minimumMelodyClearance
    }

    /// **보이스 리딩(146절)** — 직전 보이싱에서 성부가 가장 적게 움직이는 배치를 고른다.
    ///
    /// **왜 필요한가**: `buildHarmonyNotes`는 화음마다 근음 위치 스택을 처음부터 다시 쌓는다.
    /// 그래서 코드가 C→F로 가면 세 성부가 전부 5반음씩 같은 방향으로 옮겨간다(병행진행) —
    /// 합창 편곡에서 제일 먼저 피하는 움직임이고, "화음이 딱딱하다"고 들리는 원인이다. 사람이
    /// 편곡하면 공통음 C는 그대로 두고 E→F, G→A만 움직여서 총 3반음만 이동한다.
    ///
    /// 방법은 단순하다 — 코드 구성음 세 개를 놓을 수 있는 자리(옥타브)를 전부 훑어 조합을
    /// 만들고, 직전 보이싱과 **음높이 순서대로 짝지어** 이동량 합이 가장 작은 걸 고른다.
    /// 공통음을 붙잡는 배치는 그 성부의 이동량이 0이라 자연히 최소 비용이 되므로, 공통음 유지
    /// 규칙을 따로 넣을 필요가 없다. 전위(어느 성부가 어느 화음음을 맡는지)도 정렬 결과로
    /// 저절로 결정된다.
    ///
    /// 후보 수는 (구성음 3개 × 옥타브 두세 개)라 스무 개 남짓이다 — 노트마다 훑어도 부담이 없어
    /// DP 없이 매 스텝 탐욕적으로 고른다(직전 한 스텝만 보므로 전체 최적은 아니지만, 화음
    /// 진행 자체는 이미 Viterbi가 전역으로 정해뒀다).
    private static func voiceLedHarmonyNotes(
        candidate: ChordCandidate,
        melodyMIDINote: Int,
        previous: [HarmonyNote]
    ) -> [HarmonyNote] {
        let previousPitches = previous.map(\.midiNote).sorted()
        guard previousPitches.count == 3 else {
            return buildHarmonyNotes(candidate: candidate, melodyMIDINote: melodyMIDINote)
        }

        let ceiling = melodyMIDINote - minimumMelodyClearance
        let floor = melodyMIDINote - maximumMelodyToTopVoiceGap - maximumVoicingSpread
        let chordTones = [candidate.rootPitchClass, candidate.thirdPitchClass, candidate.fifthPitchClass]

        // 각 구성음이 놓일 수 있는 자리들(멜로디 아래, 상한 안쪽의 모든 옥타브).
        let placements: [[Int]] = chordTones.map { pitchClass in
            stride(from: floor, through: ceiling, by: 1).filter { $0.mod(12) == pitchClass }
        }
        guard placements.allSatisfy({ !$0.isEmpty }) else {
            return buildHarmonyNotes(candidate: candidate, melodyMIDINote: melodyMIDINote)
        }

        var bestVoicing: [Int]?
        var bestCost = Int.max
        for root in placements[0] {
            for third in placements[1] {
                for fifth in placements[2] {
                    let voicing = [root, third, fifth].sorted()
                    // 두 성부가 같은 자리에 겹치면 트라이어드가 완성되지 않는다.
                    guard voicing[0] < voicing[1], voicing[1] < voicing[2] else { continue }
                    // 리드 바로 아래에 닫힌 자리로 붙어 있어야 한다(위 두 상수 주석 참고).
                    guard melodyMIDINote - voicing[2] <= maximumMelodyToTopVoiceGap else { continue }
                    guard voicing[2] - voicing[0] <= maximumVoicingSpread else { continue }

                    let cost = zip(voicing, previousPitches).reduce(0) { $0 + abs($1.0 - $1.1) }
                    if cost < bestCost {
                        bestCost = cost
                        bestVoicing = voicing
                    }
                }
            }
        }

        guard let voicing = bestVoicing else {
            return buildHarmonyNotes(candidate: candidate, melodyMIDINote: melodyMIDINote)
        }

        // 낮은 자리부터 아랫소리/가운뎃소리/윗소리 — 이 정렬이 `Interval.displayOrder`가
        // 기대는 "음높이 내림차순" 불변식을 그대로 지켜준다.
        return zip([Interval.bass, .third, .fifth], voicing).map { interval, midiNote in
            HarmonyNote(
                interval: interval,
                midiNote: midiNote,
                frequency: NoteNameConverter.frequency(forMIDINote: midiNote),
                pitchClass: midiNote.mod(12)
            )
        }
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
