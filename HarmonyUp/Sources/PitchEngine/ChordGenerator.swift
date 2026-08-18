import Foundation

/// 판별된 조성(KeyDetector.DetectedKey)을 기준으로, 멜로디 노트 시퀀스 전체에 코드 진행을
/// 붙여서 3성부(베이스/이너보이스1(3도)/이너보이스2(5도))를 생성한다 — 아카펠라 4인 편성
/// (리드 멜로디 + 이 3성부)을 흉내낸다.
///
/// "지금 재생 중인 반주 코드"를 별도로 입력받지 않는다 — 이 앱은 반주 없이 목소리 하나만
/// 녹음/분석하는 구조라 코드 데이터가 저절로 생기는 소스가 없고, "멜로디를 녹음하면 나머지
/// 화성이 다 자동으로 나와야 한다"는 요구사항 때문이다.
///
/// **화성 모델(v2)**: 예전엔 "멜로디 음 자신이 그 순간 화음의 근음"이었는데(음마다 화음이
/// 다시 계산됨), 이제는 조성의 다이어토닉 코드 7개(I~vii°) 중 그 구간에 가장 어울리는 코드를
/// **HMM + Viterbi 알고리즘**으로 골라서 배정한다 — 화음이 멜로디 음 여러 개에 걸쳐 유지될 수
/// 있고(경과음 처리), 4성부가 멜로디를 그대로 따라 움직이는 병행 진행도 줄어든다. 근거는
/// docs/CONCEPTS.md 51절 참고.
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

        /// 포먼트(스펙트럼 포락선, 성도 길이가 만드는 음색) 이동 비율 — `PitchShifter.shift`의
        /// `formantRatio`로 그대로 전달된다(Phase 8 Task 1, docs/CONCEPTS.md 77절). 피치만
        /// 옮기던 예전 방식은 "같은 사람이 음만 이동한" 소리로 들려서, 베이스는 포먼트를
        /// 아래로(성도가 긴 실제 저음처럼), 3도/5도는 위로(맑은 두성처럼) 같이 옮겨 다른
        /// 성역의 사람이 부르는 느낌을 낸다. 정확한 수치는 코드로 검증할 수 없는 청감
        /// 영역이라, 실기기로 들어보면서 조정해나갈 시작값이다.
        var formantRatio: Double {
            switch self {
            case .bass: return 0.85
            case .third: return 1.15
            case .fifth: return 1.15
            }
        }

        /// 성부별 상대 음량 배율 — 바버샵 보이싱 관행(근음·5도를 두드러지게, 3도는 배경에
        /// 머물게, docs/CONCEPTS.md 리서치 섹션 B)을 흉내낸 시작값. pan/formantRatio와
        /// 마찬가지로 정확한 수치는 청감 영역이라 실기기로 들어보면서 조정한다.
        var gain: Float {
            switch self {
            case .bass: return 1.0
            case .third: return 0.85
            case .fifth: return 1.0
            }
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

    /// 다이어토닉 토널 기능의 표준 3분류 단순화 — Tonic(안정)/Subdominant(불안)/Dominant(긴장)이
    /// T→S→D→T로 순환하는 게 자연스럽다는 화성학 원칙(docs/CONCEPTS.md 51절 리서치)을
    /// 코드 전이 점수에 반영하는 데 쓴다.
    private enum TonalFunction {
        case tonic
        case subdominant
        case dominant
    }

    /// 다이어토닉 코드 후보 하나(스케일 디그리 0~6 중 하나 위에 3도씩 쌓은 트라이어드).
    private struct ChordCandidate {
        let scaleDegree: Int
        let rootPitchClass: Int
        let thirdPitchClass: Int
        let fifthPitchClass: Int
        let function: TonalFunction
    }

    /// - Parameters:
    ///   - melodyNotes: 멜로디 노트 시퀀스 전체(순서대로) — 각 노트의 실제 MIDI 노트와 길이(초).
    ///     Viterbi가 문맥(앞뒤 노트)을 보고 코드를 고르므로, 노트 하나만 떼어 다시 계산할 수
    ///     없다 — 항상 시퀀스 전체를 한 번에 넘겨야 한다.
    ///   - key: KeyDetector가 판별한 조성
    /// - Returns: `melodyNotes`와 인덱스가 정렬된 배열. 각 원소는 `[베이스, 이너보이스1(3도),
    ///   이너보이스2(5도)]`. 그 노트가 판별된 조성의 온음계에 속하지 않으면(예: 반음계
    ///   경과음) 새 화음을 계산하지 않고 **직전 유효 화음을 그대로 이어서 반환**한다 — 실제
    ///   백킹보컬/아카펠라 관행이 이렇다(화음 성부는 리드가 짧게 스쳐가는 경과음까지 따라
    ///   움직이지 않고, 화음을 그대로 붙잡고 있다가 다음 화성 변화에서만 움직인다). 예전엔
    ///   이 경우 nil을 반환해 재생/악보 양쪽에서 무음·쉼표로 끊겼는데, 실기기 청취 피드백
    ///   ("화음에 쉼표가 껴서 안 매끄럽다")으로 이 방식이 오히려 더 안 어울린다는 게 확인돼
    ///   바꿨다. 시퀀스 맨 앞부터 온음계 밖 음이 나와 붙잡을 직전 화음이 아직 없으면(비교
    ///   대상 없음) 그때만 nil을 유지한다. 온음계 밖 노트가 코드 진행의 문맥(앞뒤 노트가
    ///   어떤 코드를 고르는지)에 계속 영향을 주는 것은 그대로다(emissionScore가 중립 처리).
    static func harmonizeSequence(melodyNotes: [(midiNote: Int, duration: Double)], key: KeyDetector.DetectedKey) -> [[HarmonyNote]?] {
        guard !melodyNotes.isEmpty else { return [] }

        let scale = diatonicScale(tonic: key.tonicPitchClass, mode: key.mode)
        let candidates = chordCandidates(scale: scale)

        let pitchClasses = melodyNotes.map { $0.midiNote.mod(12) }
        let inScale = pitchClasses.map { scale.contains($0) }
        let path = viterbiDecode(pitchClasses: pitchClasses, durations: melodyNotes.map(\.duration), inScale: inScale, candidates: candidates)

        var lastValidHarmony: [HarmonyNote]?
        var results: [[HarmonyNote]?] = []
        results.reserveCapacity(melodyNotes.count)
        for i in melodyNotes.indices {
            guard inScale[i] else {
                results.append(lastValidHarmony)
                continue
            }
            let notes = buildHarmonyNotes(candidate: candidates[path[i]], melodyMIDINote: melodyNotes[i].midiNote)
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
    /// 만든다. 기능 매핑은 표준 3기능 이론(T/S/D)의 단순화 버전 — I/iii/vi=Tonic,
    /// ii/IV=Subdominant, V/vii°=Dominant(docs/CONCEPTS.md 51절).
    private static func chordCandidates(scale: [Int]) -> [ChordCandidate] {
        let functions: [TonalFunction] = [.tonic, .subdominant, .tonic, .subdominant, .dominant, .tonic, .dominant]
        return (0..<7).map { degree in
            ChordCandidate(
                scaleDegree: degree,
                rootPitchClass: scale[degree],
                thirdPitchClass: scale[(degree + 2) % 7],
                fifthPitchClass: scale[(degree + 4) % 7],
                function: functions[degree]
            )
        }
    }

    /// 멜로디 음 하나가 후보 코드에 얼마나 잘 맞는지 — 코드 구성음(근음/3도/5도)이면 높은 점수,
    /// 아니면 낮은(음수) 점수. 노트 길이로 가중해서, 짧은 음(경과음일 가능성)은 안 맞아도 덜
    /// 불리하고 긴 음(진짜 그 화음 위에서 부른 음일 가능성)은 안 맞으면 더 불리하게 만든다 —
    /// `KeyDetector`가 조성 판별에서 길이 가중치를 쓰는 것과 같은 원리.
    /// 온음계 밖 노트(inScale=false)는 중립(0)으로 둬서 어떤 코드도 불리하게 만들지 않는다 —
    /// 그래야 반음계 경과음 하나 때문에 앞뒤 코드 흐름이 끊기지 않는다.
    private static func emissionScore(pitchClass: Int, duration: Double, inScale: Bool, candidate: ChordCandidate) -> Double {
        guard inScale else { return 0 }
        let isChordTone = pitchClass == candidate.rootPitchClass
            || pitchClass == candidate.thirdPitchClass
            || pitchClass == candidate.fifthPitchClass
        return duration * (isChordTone ? 2.0 : -1.0)
    }

    /// 코드에서 코드로 넘어갈 때의 자연스러움 점수.
    /// - 같은 코드 유지(디그리 차이 0): 가장 큰 보너스 — 경과음이 지나가는 동안 화음이 안
    ///   바뀌도록 유도한다(이게 이번 리서치의 핵심 목표였던 "화성 리듬을 멜로디보다 느리게").
    /// - 근음이 4도 위(디그리+3) 또는 그와 동치인 5도 위(디그리+4)로 움직이는 "강한 진행":
    ///   중간 보너스(circle-of-fifths 진행 — 다이어토닉 스케일 디그리 공간에서 "+3 mod 7"을
    ///   반복하면 I-IV-vii°-iii-vi-ii-V-I라는 표준 5도권 진행이 그대로 나온다).
    /// - 3도 위/아래로 움직이는 진행: 약한 보너스. 그 외(인접/스텝와이즈 근음 진행): 중립.
    /// - Dominant(불안정) 뒤에 Subdominant로 가는 "역행"은 소폭 페널티, Dominant→Tonic
    ///   "해결"은 추가 보너스 — T→S→D→T 순환 원칙(docs/CONCEPTS.md 51절 리서치) 반영.
    private static func transitionScore(from: ChordCandidate, to: ChordCandidate) -> Double {
        let diff = (to.scaleDegree - from.scaleDegree + 7) % 7
        var score: Double
        switch diff {
        case 0: score = 3.0
        case 3, 4: score = 2.0
        case 2, 5: score = 1.0
        default: score = 0.0
        }

        if from.function == .dominant {
            if to.function == .subdominant { score -= 1.0 }
            if to.function == .tonic { score += 1.0 }
        }
        return score
    }

    /// Viterbi 알고리즘 — 각 노트마다 "이 코드를 골랐을 때 여기까지의 누적 점수가 최대인 경로"를
    /// 동적계획법으로 계산하고(dp), 마지막 노트에서 가장 점수가 높은 코드부터 backpointer를 따라
    /// 거꾸로 되짚어 전체 시퀀스의 최적 코드열을 복원한다. 노트 수(n)×코드 후보(7)×코드 후보(7)
    /// 규모라 녹음 하나(최대 수십 개 노트)에 밀리초 단위로 끝난다.
    private static func viterbiDecode(
        pitchClasses: [Int],
        durations: [Double],
        inScale: [Bool],
        candidates: [ChordCandidate]
    ) -> [Int] {
        let n = pitchClasses.count
        let k = candidates.count

        var dp = [[Double]](repeating: [Double](repeating: 0, count: k), count: n)
        var backpointer = [[Int]](repeating: [Int](repeating: 0, count: k), count: n)

        for c in 0..<k {
            dp[0][c] = emissionScore(pitchClass: pitchClasses[0], duration: durations[0], inScale: inScale[0], candidate: candidates[c])
        }

        for i in 1..<n {
            for c in 0..<k {
                var bestScore = -Double.infinity
                var bestPrev = 0
                for prevC in 0..<k {
                    let score = dp[i - 1][prevC] + transitionScore(from: candidates[prevC], to: candidates[c])
                    if score > bestScore {
                        bestScore = score
                        bestPrev = prevC
                    }
                }
                dp[i][c] = bestScore + emissionScore(pitchClass: pitchClasses[i], duration: durations[i], inScale: inScale[i], candidate: candidates[c])
                backpointer[i][c] = bestPrev
            }
        }

        var path = [Int](repeating: 0, count: n)
        path[n - 1] = (0..<k).max(by: { dp[n - 1][$0] < dp[n - 1][$1] }) ?? 0
        if n > 1 {
            for i in stride(from: n - 1, to: 0, by: -1) {
                path[i - 1] = backpointer[i][path[i]]
            }
        }
        return path
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
