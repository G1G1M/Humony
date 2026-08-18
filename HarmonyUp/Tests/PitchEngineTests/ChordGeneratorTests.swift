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

    // 온음계 밖(반음계) 음은 그 자리의 화음만 nil이어야 하고, 앞뒤 음의 화음 판단(문맥)은
    // 끊기지 않아야 한다 — C4/E4 둘 다 여전히 화음을 갖는다.
    func testOutOfScaleNoteReturnsNilWithoutBreakingContext() {
        let notes = [(midiNote: 60, duration: 0.3), (midiNote: 61, duration: 0.3), (midiNote: 64, duration: 0.3)] // C4, C#4(반음계), E4
        let result = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        XCTAssertEqual(result.count, 3)
        XCTAssertNotNil(result[0])
        XCTAssertNil(result[1])
        XCTAssertNotNil(result[2])
    }

    // 이번 작업의 핵심 계약: 짧게 지나가는 경과음(도-레-미, 레는 C장조 화음의 구성음이
    // 아님) 위에서는 화음이 안 바뀌고 하나로 유지돼야 한다 — 화성 리듬이 멜로디 리듬보다
    // 느려야 한다는 리서치 결론(docs/CONCEPTS.md 51절)을 직접 검증한다. 짧은 길이(0.2초)를
    // 써야 한다 — 길게 끌면(경과음이 아니라 진짜 화성 변화로 봐야 하므로) 오히려 코드가
    // 바뀌는 게 맞는 동작이다(아래 testLongHeldNotesPreferSwitchingChordsOverStaying 참고).
    func testShortPassingToneDoesNotChangeChord() {
        let notes = [(midiNote: 60, duration: 0.2), (midiNote: 62, duration: 0.2), (midiNote: 64, duration: 0.2)] // C4-D4-E4
        let result = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))
        let basses = result.compactMap { $0 }.map { harmonyByInterval($0)[.bass]!.pitchClass }

        XCTAssertEqual(basses.count, 3, "세 음 다 온음계 안이라 전부 화음이 있어야 함")
        XCTAssertEqual(Set(basses).count, 1, "경과음 구간 전체가 하나의 코드(같은 베이스 음이름)로 유지돼야 함")
    }

    // 반대로 충분히 길게 끄는 음들(도→레→솔)은 서로 다른 코드로 진짜 바뀌어야 한다.
    // 도-레 두 음만 보면 "레를 구성음으로 갖는 코드"가 여러 개(ii/V/vii°)라 어느 쪽이든
    // 전이 점수가 동률일 수 있는데, 마지막에 솔(G)까지 이어 붙이면 "도-레-솔 셋 다 구성음으로
    // 갖으면서 전이 점수 합도 최대인" 조합이 I→V→V(근음 4도 위로 강하게 진행한 뒤 그 자리에
    //머무름) 하나로 유일하게 좁혀진다 — 근음 진행 선호 규칙이 실제로 동작하는지 확인한다.
    func testLongHeldNotesPreferStrongRootMotionWhenSwitchingChords() {
        let notes = [(midiNote: 60, duration: 1.0), (midiNote: 62, duration: 1.0), (midiNote: 67, duration: 1.0)] // C4, D4, G4(전부 길게)
        let result = ChordGenerator.harmonizeSequence(melodyNotes: notes, key: key(tonic: 0, mode: .major))

        guard let first = result[0], let second = result[1], let third = result[2] else {
            return XCTFail("셋 다 온음계 안이라 화음이 있어야 함")
        }
        XCTAssertEqual(harmonyByInterval(first)[.bass]?.pitchClass, 0, "도 위는 I(근음 C)여야 함")
        XCTAssertEqual(harmonyByInterval(second)[.bass]?.pitchClass, 7, "레 위는 V(근음 G)로 강한 진행을 타야 함")
        // 솔(G)은 V의 근음이면서 동시에 I의 5도이기도 해서, "V에 그대로 머무르기"와
        // "I로 해결하기"(V→I는 근음이 4도 위로 움직이는 강한 진행 + 도미넌트→토닉 해결
        // 보너스가 겹쳐 "머무르기"와 정확히 동점) 둘 다 이론적으로 똑같이 타당하다 —
        // 어느 쪽이든 화성적으로 맞으므로 둘 중 하나이기만 하면 된다.
        XCTAssertTrue([0, 7].contains(harmonyByInterval(third)[.bass]?.pitchClass), "솔 위는 V(머무름) 또는 I(해결) 중 하나여야 함")
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

    // 성부별 상대 음량 배율(믹스 밸런스) — 바버샵 보이싱 관행대로 3도만 배경으로 살짝
    // 낮아야 하고, 베이스/5도는 원래 음량(1.0)을 유지해야 한다.
    func testGainKeepsThirdSlightlyRecessed() {
        XCTAssertEqual(ChordGenerator.Interval.bass.gain, 1.0)
        XCTAssertEqual(ChordGenerator.Interval.fifth.gain, 1.0)
        XCTAssertLessThan(ChordGenerator.Interval.third.gain, 1.0)
    }

}
