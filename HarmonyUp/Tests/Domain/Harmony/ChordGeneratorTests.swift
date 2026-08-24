import XCTest
@testable import HarmonyUp

final class ChordGeneratorTests: XCTestCase {

    private func key(tonic: Int, mode: KeyDetector.Mode) -> KeyDetector.DetectedKey {
        KeyDetector.DetectedKey(tonicPitchClass: tonic, mode: mode, confidence: 1.0)
    }

    private func harmonyByInterval(_ harmony: [ChordGenerator.HarmonyNote]) -> [ChordGenerator.Interval: ChordGenerator.HarmonyNote] {
        Dictionary(uniqueKeysWithValues: harmony.map { ($0.interval, $0) })
    }

    // 여러 성부를 동시에 재생할 때(VoiceClipPlayer.playTracks) 실제로 좌우로 갈라지는지의
    // 근거가 되는 값 — 3도는 왼쪽, 5도는 오른쪽, 베이스는 중앙이어야 한다.
    // Phase 8 Task 2(공간 패닝) 사양대로 정확한 값을 검증한다 — 베이스는 중앙에 살짝
    // 치우치고, 3도/5도는 서로 반대편으로 크게 갈라진다(docs/CONCEPTS.md 77절).
    func testPanSpreadsThirdAndFifthToOppositeSides() {
        XCTAssertEqual(ChordGenerator.Interval.bass.pan, -0.25)
        XCTAssertEqual(ChordGenerator.Interval.third.pan, 0.45)
        XCTAssertEqual(ChordGenerator.Interval.fifth.pan, -0.55)
        XCTAssertNotEqual(ChordGenerator.Interval.third.pan.sign, ChordGenerator.Interval.fifth.pan.sign)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(ChordGenerator.harmonizeSequence(melodyNotes: [], key: key(tonic: 0, mode: .major)).isEmpty)
    }

    func testOutputCountMatchesInputCount() {
        let notes = [(midiNote: 60, duration: 0.3), (midiNote: 62, duration: 0.3), (midiNote: 64, duration: 0.3)]
        let result = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))
        XCTAssertEqual(result.count, 3)
    }

    // 온음계 밖(반음계) 음은 새 화음을 계산하지 않고 직전 화음을 그대로 이어받아야 한다 —
    // 실제 백킹보컬처럼 화음 성부가 경과음까지 따라 움직이지 않고 붙잡고 있는 게 더
    // 매끄럽다는 실기기 청취 피드백으로 바뀐 동작(예전엔 nil=무음/쉼표였음). C#4(반음계)
    // 자리의 화음이 앞 C4의 화음과 완전히 같아야(같은 베이스 pitchClass) 하고, 뒤 E4는
    // 자기 자신의 화음을 새로 갖는다(이 예시에서 우연히 같을 수도 있어 pitchClass가 아니라
    // 인스턴스 자체가 앞 화음과 동일한지를 본다).
    func testOutOfScaleNoteCarriesForwardPreviousHarmony() {
        let notes = [(midiNote: 60, duration: 0.3), (midiNote: 61, duration: 0.3), (midiNote: 64, duration: 0.3)] // C4, C#4(반음계), E4
        let result = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        XCTAssertEqual(result.count, 3)
        guard let first = result[0], let second = result[1] else {
            return XCTFail("첫 음과 반음계 경과음 둘 다 화음을 가져야 함(경과음은 직전 화음을 이어받음)")
        }
        XCTAssertNotNil(result[2])
        XCTAssertEqual(harmonyByInterval(second)[.bass]!.midiNote, harmonyByInterval(first)[.bass]!.midiNote, "반음계 경과음은 직전 화음과 완전히 같은 자리를 이어받아야 함")
    }

    // 시퀀스 맨 앞부터 온음계 밖 음이면 이어받을 직전 화음 자체가 없으니 nil이 맞다.
    func testLeadingOutOfScaleNoteWithNoPreviousHarmonyStaysNil() {
        let notes = [(midiNote: 61, duration: 0.3), (midiNote: 60, duration: 0.3)] // C#4(반음계, 맨 앞), C4
        let result = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        XCTAssertNil(result[0])
        XCTAssertNotNil(result[1])
    }

    // 133절(v2 재도입)의 핵심 계약: 짧은 경과음은 코드 판단에 거의 영향을 주지 않아야
    // 한다(방출 점수가 길이로 가중되므로) — 매우 짧은 도-레-미 시퀀스는 "같은 코드 유지"
    // 전이 보너스(+3.0)가 미세한 방출 점수 차이를 압도해서 베이스가 3음 내내 그대로여야
    // 한다. v1(101절)이었다면 매번 그 음 자신을 근음으로 새로 계산해 베이스가 [0,2,4]로
    // 바뀌었을 자리다.
    func testVeryShortPassingTonesHoldTheSameChord() {
        let notes = [(midiNote: 60, duration: 0.02), (midiNote: 62, duration: 0.02), (midiNote: 64, duration: 0.02)] // C4-D4-E4, 아주 짧게
        let result = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))
        let basses = result.compactMap { $0 }.map { harmonyByInterval($0)[.bass]!.pitchClass }

        XCTAssertEqual(basses.count, 3)
        XCTAssertEqual(Set(basses).count, 1, "아주 짧은 경과음 3개는 화음이 한 번도 안 바뀌고 그대로 유지돼야 함, 실제 \(basses)")
    }

    // 반대로 충분히 긴 음이 지금 코드에 안 맞는 음이면, "같은 코드 유지" 보너스를 방출
    // 점수 차이가 압도해서 코드가 실제로 바뀌어야 한다 — 안 그러면 그냥 항상 첫 코드에
    // 머무는 퇴화한 알고리즘이 된다. 도(C, pc0)와 시(B, pc11)는 공통으로 속하는 다이어토닉
    // 코드가 하나도 없다(C는 I/IV/vi, B는 iii/V/vii°) — 그래서 두 음 다 충분히 길면 "같은
    // 코드로 둘 다 설명하기"가 애초에 불가능해 코드가 반드시 바뀌어야 한다.
    func testLongOffChordNoteChangesTheChord() throws {
        let notes = [(midiNote: 60, duration: 3.0), (midiNote: 71, duration: 3.0)] // C4(3초) -> B4(3초)
        let result = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))
        let first = try XCTUnwrap(result[0])
        let second = try XCTUnwrap(result[1])

        XCTAssertNotEqual(harmonyByInterval(first)[.bass]!.pitchClass, harmonyByInterval(second)[.bass]!.pitchClass, "충분히 긴 음이 기존 코드에 안 맞으면 코드가 바뀌어야 함")
    }

    func testCMajorTriadFromRootMelodyNote() throws {
        // C4(MIDI 60) 하나만 있는 시퀀스 — 베이스는 한 옥타브(또는 그 근처) 아래, 3도/5도는
        // 베이스와 멜로디 "사이"에 들어와야 한다는 배치 계약을 확인한다.
        let result = ChordGenerator.harmonizeSequence(melodyNotes: [(midiNote: 60, duration: 0.3)], key: key(tonic: 0, mode: .major))
        let harmony = try XCTUnwrap(result[0])
        let byInterval = harmonyByInterval(harmony)

        XCTAssertEqual(harmony.count, 3)
        XCTAssertLessThan(byInterval[.bass]!.midiNote, byInterval[.third]!.midiNote)
        XCTAssertLessThan(byInterval[.third]!.midiNote, byInterval[.fifth]!.midiNote)
        XCTAssertLessThan(byInterval[.fifth]!.midiNote, 60)
    }

    func testAMinorTriadIntervalQuality() throws {
        // A3(MIDI 57) 하나만 있는 시퀀스에서, A단조 조성이면 베이스가 무슨 코드로 뽑히든
        // "장/단3도가 조성에 맞게 자동으로 섞여 나온다"는 성질은 diatonicScale 재사용으로
        // 그대로 보장된다 — 최소한 3도/5도 간격 자체가 온음계 간격(3~4/6~8반음)인지 확인한다.
        let result = ChordGenerator.harmonizeSequence(melodyNotes: [(midiNote: 57, duration: 0.3)], key: key(tonic: 9, mode: .minor))
        let harmony = try XCTUnwrap(result[0])
        let byInterval = harmonyByInterval(harmony)

        let thirdGap = byInterval[.third]!.midiNote - byInterval[.bass]!.midiNote
        let fifthGap = byInterval[.fifth]!.midiNote - byInterval[.bass]!.midiNote
        XCTAssertTrue((3...4).contains(thirdGap), "3도 간격은 3~4반음이어야 함, 실제 \(thirdGap)")
        XCTAssertTrue((6...8).contains(fifthGap), "5도 간격은 6~8반음이어야 함, 실제 \(fifthGap)")
    }

    // 성부 교차 방지 불변식 — 스케일 전체를 순회해도 베이스<3도<5도<멜로디, 그리고
    // 베이스는 멜로디보다 최소 9반음 이상 아래여야 한다(minimumBassToMelodyGap 문서 참고).
    func testVoicesNeverCrossAcrossFullScale() {
        for melodyMIDINote in 60...83 {
            let result = ChordGenerator.harmonizeSequence(melodyNotes: [(midiNote: melodyMIDINote, duration: 0.3)], key: key(tonic: 0, mode: .major))
            guard let harmony = result[0] else { continue } // 온음계 밖 음은 건너뜀
            let byInterval = harmonyByInterval(harmony)

            XCTAssertGreaterThanOrEqual(melodyMIDINote - byInterval[.bass]!.midiNote, 9, "멜로디 MIDI \(melodyMIDINote)")
            XCTAssertLessThan(byInterval[.bass]!.midiNote, byInterval[.third]!.midiNote)
            XCTAssertLessThan(byInterval[.third]!.midiNote, byInterval[.fifth]!.midiNote)
            XCTAssertLessThan(byInterval[.fifth]!.midiNote, melodyMIDINote)
        }
    }

    // 성부별 상대 음량 배율(믹스 밸런스) — 사용자가 "4개 성부가 다 같은 크기로 나오게 해달라,
    // 직접 들으며 조정하겠다"고 요청해 전부 균등(1.0)으로 되돌렸다(바버샵풍으로 3도만 살짝
    // 낮추던 이전 값 폐기).
    func testGainIsEqualAcrossAllVoices() {
        XCTAssertEqual(ChordGenerator.Interval.bass.gain, 1.0)
        XCTAssertEqual(ChordGenerator.Interval.third.gain, 1.0)
        XCTAssertEqual(ChordGenerator.Interval.fifth.gain, 1.0)
    }

    /// 화면에 성부를 나열하는 순서(`Interval.displayOrder`)는 **실제 음높이 내림차순과 항상
    /// 일치해야 한다** — 악보든 조작부든 "위에 있는 게 높은 음"이라는 오선보 관례를 따르는데,
    /// 그 순서가 실제 배치와 어긋나면 화면이 거짓말을 하게 된다. 순서를 한 곳
    /// (`displayOrder`)에 모아 화면끼리는 통일했으니, 이제 그 순서 자체가 맞는지를 여기서
    /// 지킨다(139절 이후 UI 크리틱으로 조작부/악보 순서가 정반대였던 게 드러나 통일한 뒤 추가).
    func testDisplayOrderMatchesActualPitchOrderAcrossFullRange() {
        for melodyMIDINote in 48...84 {
            let result = ChordGenerator.harmonizeSequence(
                melodyNotes: [(midiNote: melodyMIDINote, duration: 0.3)],
                key: key(tonic: 0, mode: .major)
            )
            guard let harmony = result.first ?? nil else { continue }

            let midiNotes = ChordGenerator.Interval.displayOrder.compactMap { interval in
                harmony.first { $0.interval == interval }?.midiNote
            }
            XCTAssertEqual(midiNotes.count, ChordGenerator.Interval.displayOrder.count, "성부가 빠졌다")
            XCTAssertEqual(
                midiNotes, midiNotes.sorted(by: >),
                "멜로디 \(melodyMIDINote)에서 displayOrder가 음높이 내림차순이 아니다: \(midiNotes)"
            )
            // 멜로디는 언제나 모든 화음 성부보다 위에 있다.
            XCTAssertLessThan(midiNotes[0], melodyMIDINote)
        }
    }
    // MARK: - 성부 휴머나이즈 (145절)

    /// 이 기능의 존재 이유 자체 — 세 성부가 같은 값을 가지면 "완벽히 겹친 클론"으로 되돌아간다.
    func testHarmonyVoicesHaveDistinctDetuneAndTiming() {
        let intervals: [ChordGenerator.Interval] = [.bass, .third, .fifth]

        let detunes = intervals.map(\.detuneCents)
        XCTAssertEqual(Set(detunes).count, intervals.count, "성부끼리 디튠 값이 겹친다")

        let offsets = intervals.map(\.onsetOffsetSeconds)
        XCTAssertEqual(Set(offsets).count, intervals.count, "성부끼리 타이밍 오프셋이 겹친다")
    }

    /// 휴머나이즈는 "미세하게" 어긋나야 한다 — 크면 음정 오류/박자 밀림으로 들린다.
    func testHumanizationStaysWithinPerceptuallySafeRange() {
        for interval in [ChordGenerator.Interval.bass, .third, .fifth] {
            XCTAssertLessThanOrEqual(abs(interval.detuneCents), 10.0, "\(interval.koreanLabel) 디튠이 음정 오류로 들릴 만큼 크다")
            XCTAssertGreaterThanOrEqual(interval.onsetOffsetSeconds, 0)
            XCTAssertLessThanOrEqual(interval.onsetOffsetSeconds, 0.04, "\(interval.koreanLabel) 지연이 박자 밀림으로 들릴 만큼 크다")
        }
    }

    /// cent → 주파수 비율 변환이 맞는지(1200 cent = 2배).
    func testDetuneRatioMatchesCentDefinition() {
        for interval in [ChordGenerator.Interval.bass, .third, .fifth] {
            let expected = pow(2.0, interval.detuneCents / 1200.0)
            XCTAssertEqual(interval.detuneRatio, expected, accuracy: 1e-9)
        }
    }

    // MARK: - 보이스 리딩 (146절)

    /// 화음이 바뀔 때 성부가 얼마나 움직이는지(반음 합)를 인접 쌍마다 계산한다.
    /// 성부는 음높이 순으로 짝지어 비교한다 — 어느 성부가 어느 화음음을 맡는지는
    /// 보이스 리딩이 매번 새로 정하므로, `interval` 라벨이 아니라 자리로 비교해야 한다.
    private func movementsPerChange(_ harmonies: [[ChordGenerator.HarmonyNote]?]) -> [Int] {
        let voicings = harmonies.compactMap { $0?.map(\.midiNote).sorted() }
        return zip(voicings, voicings.dropFirst()).map { previous, current in
            zip(previous, current).reduce(0) { $0 + abs($1.1 - $1.0) }
        }
    }

    /// 근음 위치로만 쌓던 예전 방식 — 새 방식과 총 이동량을 비교하기 위한 재현.
    /// (베이스를 멜로디 9반음 아래 이하의 가장 가까운 자리에 놓고, 그 위에 3도·5도를 쌓는다.)
    private func rootPositionMovements(melodyNotes: [Int], harmonies: [[ChordGenerator.HarmonyNote]?]) -> [Int] {
        var voicings: [[Int]] = []
        for (index, harmony) in harmonies.enumerated() {
            guard let harmony else { continue }
            let pitchClasses = Set(harmony.map { $0.midiNote.mod(12) })
            let ceiling = melodyNotes[index] - 9
            let base = ceiling - ceiling.mod(12)
            var stacked: [Int] = []
            for pitchClass in pitchClasses.sorted() {
                var note = base + pitchClass
                if note > ceiling { note -= 12 }
                stacked.append(note)
            }
            voicings.append(stacked.sorted())
        }
        return zip(voicings, voicings.dropFirst()).map { previous, current in
            zip(previous, current).reduce(0) { $0 + abs($1.1 - $1.0) }
        }
    }

    /// 보이스 리딩의 존재 이유 — 화음이 바뀔 때 세 성부가 통째로 같은 방향으로 옮겨가는
    /// 병행진행 대신, 각 성부가 가장 가까운 화음음으로 옮겨가야 한다. 근음 위치 스택은
    /// 코드 루트가 움직이는 만큼 세 성부가 전부 그만큼 움직인다(C→F면 5+5+5=15).
    func testVoiceLeadingMovesLessThanRootPositionStacking() {
        let melody = [60, 62, 64, 65, 67, 65, 64, 62, 60, 59, 60]
        let notes = melody.map { (midiNote: $0, duration: 0.6) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        let newTotal = movementsPerChange(harmonies).reduce(0, +)
        let oldTotal = rootPositionMovements(melodyNotes: melody, harmonies: harmonies).reduce(0, +)

        XCTAssertLessThan(newTotal, oldTotal, "보이스 리딩이 근음 위치 스택보다 더 많이 움직인다(새 \(newTotal) / 예전 \(oldTotal))")
    }

    /// 어떤 성부도 한 번에 크게 뛰지 않아야 한다 — 도약이 크면 "사람이 부르는 선율"이 아니라
    /// 화음이 통째로 순간이동하는 것처럼 들린다. 완전5도(7반음)를 상한으로 잡는다.
    func testNoVoiceLeapsMoreThanAPerfectFifth() {
        let melody = [60, 62, 64, 65, 67, 69, 71, 72, 71, 69, 67, 65, 64, 62, 60]
        let notes = melody.map { (midiNote: $0, duration: 0.5) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))
        let voicings = harmonies.compactMap { $0?.map(\.midiNote).sorted() }

        for (previous, current) in zip(voicings, voicings.dropFirst()) {
            for (before, after) in zip(previous, current) {
                XCTAssertLessThanOrEqual(abs(after - before), 7, "성부가 \(abs(after - before))반음 도약했다: \(previous) → \(current)")
            }
        }
    }

    /// 인접한 두 화음이 같은 음이름을 공유하면, 그 음을 맡은 성부는 **그대로 머물러야** 한다.
    /// 공통음 유지는 합창 편곡의 기본이고, 이게 되면 화음이 바뀌어도 선이 끊기지 않는다.
    func testCommonTonesAreHeldWhenAdjacentChordsShareANote() {
        let melody = [60, 62, 64, 65, 67, 65, 64, 62, 60]
        let notes = melody.map { (midiNote: $0, duration: 0.6) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))
        let voicings = harmonies.compactMap { $0?.map(\.midiNote).sorted() }

        for (previous, current) in zip(voicings, voicings.dropFirst()) {
            let sharedPitchClasses = Set(previous.map { $0.mod(12) }).intersection(current.map { $0.mod(12) })
            guard !sharedPitchClasses.isEmpty else { continue }

            let heldNotes = Set(previous).intersection(current)
            XCTAssertFalse(
                heldNotes.isEmpty,
                "공통 음이름 \(sharedPitchClasses.sorted())이 있는데 붙잡은 성부가 없다: \(previous) → \(current)"
            )
        }
    }

    /// 전위를 쓰더라도 트라이어드 구성음 세 개가 빠짐없이, 중복 없이 들어 있어야 한다.
    func testEveryVoicingContainsAllThreeChordTonesExactlyOnce() {
        let melody = [60, 62, 64, 65, 67, 69, 71, 72]
        let notes = melody.map { (midiNote: $0, duration: 0.6) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        for harmony in harmonies.compactMap({ $0 }) {
            let pitchClasses = harmony.map { $0.midiNote.mod(12) }
            XCTAssertEqual(Set(pitchClasses).count, 3, "성부끼리 같은 음이름을 중복해서 부른다: \(pitchClasses.sorted())")
        }
    }

    /// 보이스 리딩이 들어가도 지켜야 할 배치 계약 — 시퀀스 어디서든 성부가 교차하지 않고
    /// 전부 멜로디 아래에 있어야 한다(`displayOrder`가 이 순서에 기대고 있다).
    func testVoicesStayOrderedAndBelowMelodyThroughoutSequence() {
        let melody = [60, 67, 62, 72, 64, 59, 65, 71, 60]
        let notes = melody.map { (midiNote: $0, duration: 0.5) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        for (index, harmony) in harmonies.enumerated() {
            guard let harmony else { continue }
            let byInterval = harmonyByInterval(harmony)
            XCTAssertLessThan(byInterval[.bass]!.midiNote, byInterval[.third]!.midiNote, "\(index)번째")
            XCTAssertLessThan(byInterval[.third]!.midiNote, byInterval[.fifth]!.midiNote, "\(index)번째")
            XCTAssertLessThan(byInterval[.fifth]!.midiNote, melody[index], "\(index)번째 성부가 멜로디를 넘었다")
        }
    }

    /// 성부 이름은 이제 화음음(3도/5도)이 아니라 **자리**를 가리킨다 — 전위를 쓰면 같은 성부가
    /// 매번 다른 화음음을 맡기 때문에 "3도"라는 이름이 거짓이 된다(146절, 사용자 결정).
    func testVoiceLabelsDescribePositionNotChordTone() {
        XCTAssertEqual(ChordGenerator.Interval.fifth.koreanLabel, "윗소리")
        XCTAssertEqual(ChordGenerator.Interval.third.koreanLabel, "가운뎃소리")
        XCTAssertEqual(ChordGenerator.Interval.bass.koreanLabel, "아랫소리")
    }

    /// 저장 키는 바뀌면 안 된다 — 기존 기록(SwiftData)이 성부를 이 문자열로 찾는다.
    func testStorageKeysAreUnchangedByRelabeling() {
        XCTAssertEqual(ChordGenerator.Interval.bass.storageKey, "bass")
        XCTAssertEqual(ChordGenerator.Interval.third.storageKey, "third")
        XCTAssertEqual(ChordGenerator.Interval.fifth.storageKey, "fifth")
    }

    /// 화음은 언제나 멜로디 아래에서 부딪히지 않을 만큼 떨어져 있어야 하고, **코드가 바뀌는
    /// 순간에는** 리드 한 옥타브 안쪽으로 다시 붙어야 한다.
    ///
    /// 코드가 유지되는 동안에는 간격이 그보다 벌어질 수 있다 — 147절에 자리를 고정했기 때문이다.
    /// 따라 올라가려면 전위를 바꿔야 하는데, 그게 "아무 일도 없는데 화음이 움직인다"의 원인이었다.
    func testHarmonyRealignsUnderTheMelodyWheneverTheChordChanges() {
        let melody = [60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77, 76, 74, 72, 69, 65, 60]
        let notes = melody.map { (midiNote: $0, duration: 0.6) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        var previousChord: Set<Int>?
        for (index, harmony) in harmonies.enumerated() {
            guard let harmony else { continue }
            let top = harmony.map(\.midiNote).max()!
            let gap = melody[index] - top
            XCTAssertGreaterThanOrEqual(gap, 2, "\(index)번째: 화음이 멜로디에 너무 붙어 부딪힌다(\(gap)반음)")

            let chord = Set(harmony.map { $0.midiNote.mod(12) })
            if chord != previousChord {
                XCTAssertLessThanOrEqual(gap, 12, "\(index)번째: 코드가 바뀌었는데도 화음이 \(gap)반음 떨어져 있다")
            }
            previousChord = chord
        }
    }

    /// 147절의 핵심 — 코드가 유지되는 동안에는 자리(전위)가 바뀌면 안 된다. 화성적으로 아무
    /// 일도 없는데 화음이 발밑에서 움직이면 "부자연스럽게 화음이 들어간다"로 들린다.
    /// 멜로디가 화음 쪽으로 내려와 부딪히게 되는 경우만 예외로 허용한다.
    func testVoicingDoesNotShiftWhileTheChordIsHeld() {
        let melody = [60, 62, 64, 65, 67, 69, 71, 72, 74, 76, 77, 76, 74, 72, 71, 69, 67, 65, 64, 62, 60]
        let notes = melody.map { (midiNote: $0, duration: 0.6) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        var previousChord: Set<Int>?
        var previousVoicing: [Int]?
        for (index, harmony) in harmonies.enumerated() {
            guard let harmony else { continue }
            let voicing = harmony.map(\.midiNote).sorted()
            let chord = Set(voicing.map { $0.mod(12) })

            if let previousChord, let previousVoicing, chord == previousChord {
                // 직전 자리를 그대로 써도 **되는** 상황이라면 바뀌면 안 된다. 쓸 수 있는 조건은
                // 두 가지다 — 멜로디와 안 부딪히고(위), 시프트로 만들 수 있을 만큼 가깝고(아래).
                // 아래쪽 조건이 깨지면 코드가 유지돼도 자리를 다시 잡아야 한다(147절).
                let fits = previousVoicing.max()! <= melody[index] - 2
                    && previousVoicing.min()! >= melody[index] - 16
                if fits {
                    XCTAssertEqual(
                        voicing, previousVoicing,
                        "\(index)번째: 코드가 그대로인데 자리가 옮겨졌다 \(previousVoicing) → \(voicing)"
                    )
                }
            }
            previousChord = chord
            previousVoicing = voicing
        }
    }

    /// 화음은 닫힌 자리(close position)로 유지한다 — 옥타브를 자유롭게 고르게 두면 베이스만
    /// 저 아래로 떨어져 가운데가 텅 빈 화음이 된다.
    func testVoicingStaysInClosePosition() {
        let melody = [60, 64, 67, 72, 67, 64, 60, 59, 62, 65, 69]
        let notes = melody.map { (midiNote: $0, duration: 0.6) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        for (index, harmony) in harmonies.enumerated() {
            guard let harmony else { continue }
            let pitches = harmony.map(\.midiNote).sorted()
            XCTAssertLessThanOrEqual(pitches[2] - pitches[0], 12, "\(index)번째 화음이 한 옥타브보다 넓게 벌어졌다: \(pitches)")
        }
    }

    /// **소리를 만드는 방식에서 오는 제약** — 화음 성부는 사용자가 부른 그 음을 피치 시프트해서
    /// 만들기 때문에, 너무 많이 내리면 WORLD 재합성이 뭉개져 웅웅거린다. 실기기 로그(147절)에서
    /// 멜로디 E4(330Hz)에 아랫소리가 A1(55Hz)으로 배치된 사례가 나왔다 — 2.6옥타브 다운시프트다.
    ///
    /// 재현 조건이 중요하다: **낮은 음으로 시작해 한 옥타브 넘게 올라가는** 멜로디여야 한다.
    /// 코드가 자주 바뀌는 짧은 테스트 멜로디로는 안 잡혔다.
    func testNoVoiceIsShiftedTooFarBelowTheMelody() {
        let melody = [50, 51, 55, 60, 62, 60, 59, 56, 57, 64, 54, 64, 66, 64, 62, 61, 62, 67, 67, 69, 67, 66, 64, 62, 60, 59, 56, 62, 64, 53, 54, 55]
        let notes = melody.map { (midiNote: $0, duration: 0.4) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 7, mode: .major))

        for (index, harmony) in harmonies.enumerated() {
            guard let harmony else { continue }
            let lowest = harmony.map(\.midiNote).min()!
            let downshift = melody[index] - lowest
            XCTAssertLessThanOrEqual(
                downshift, 16,
                "\(index)번째: 멜로디 \(melody[index])에 화음 최저음 \(lowest) — \(downshift)반음이나 내려 시프트해야 한다"
            )
        }
    }

    /// 온음계 밖 음은 직전 화음을 이어받는데, **그 자리가 지금 멜로디에 대해 유효한지 확인해야 한다.**
    /// 예전엔 그냥 이어받기만 해서 경과음에서 멜로디가 뚝 떨어지면 화음이 멜로디 위로 올라갔다.
    func testCarriedForwardHarmonyNeverEndsUpAboveTheMelody() {
        // G장조에서 F내추럴(53)·C#(61) 같은 온음계 밖 음이 멜로디가 낮아지는 자리에 오도록 배치.
        let melody = [67, 69, 67, 66, 64, 53, 54, 55, 62, 61, 55, 53]
        let notes = melody.map { (midiNote: $0, duration: 0.4) }
        let harmonies = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 7, mode: .major))

        for (index, harmony) in harmonies.enumerated() {
            guard let harmony else { continue }
            let top = harmony.map(\.midiNote).max()!
            XCTAssertLessThan(
                top, melody[index],
                "\(index)번째: 화음 윗소리 \(top)가 멜로디 \(melody[index])를 넘었다 — 성부가 뒤집혔다"
            )
        }
    }

    /// 첫 화음도 다른 화음과 똑같은 제약을 지켜야 한다 — 예전엔 첫 화음만 근음 위치로 쌓아서,
    /// 첫 음이 낮으면(D3) 아랫소리가 A1까지 내려갔다.
    func testFirstChordRespectsTheDownshiftLimitEvenForLowMelodies() {
        for melodyMIDINote in 45...72 {
            let result = ChordGenerator.harmonizeSequence(
                melodyNotes: [(midiNote: melodyMIDINote, duration: 0.5)],
                key: key(tonic: 0, mode: .major)
            )
            guard let harmony = result.first ?? nil else { continue }
            let lowest = harmony.map(\.midiNote).min()!
            XCTAssertLessThanOrEqual(
                melodyMIDINote - lowest, 16,
                "멜로디 \(melodyMIDINote)의 첫 화음 최저음이 \(lowest)까지 내려갔다"
            )
        }
    }

}
