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

}
