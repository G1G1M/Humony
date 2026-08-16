import XCTest
@testable import HarmonyUp

final class ChordGeneratorTests: XCTestCase {

    private func key(tonic: Int, mode: KeyDetector.Mode) -> KeyDetector.DetectedKey {
        KeyDetector.DetectedKey(tonicPitchClass: tonic, mode: mode, confidence: 1.0)
    }

    /// 반환된 배열이 항상 [베이스, 3도, 5도] 순서라는 계약을 매 테스트에서 재확인하지 않도록 헬퍼로 뽑았다.
    private func harmonyByInterval(_ harmony: [ChordGenerator.HarmonyNote]) -> [ChordGenerator.Interval: ChordGenerator.HarmonyNote] {
        Dictionary(uniqueKeysWithValues: harmony.map { ($0.interval, $0) })
    }

    func testCMajorTriadFromRootMelodyNote() throws {
        // C4(MIDI 60) 위에 C장조 3화음(C-E-G)을 쌓으면, 베이스는 한 옥타브 아래 C3(48),
        // 3도/5도는 베이스와 멜로디 "사이"(E3=52, G3=55)에 들어와야 한다.
        let melodyFrequency = NoteNameConverter.frequency(forMIDINote: 60)
        let harmony = try XCTUnwrap(ChordGenerator.generateHarmony(melodyFrequency: melodyFrequency, key: key(tonic: 0, mode: .major)))
        let byInterval = harmonyByInterval(harmony)

        XCTAssertEqual(harmony.count, 3)
        XCTAssertEqual(byInterval[.bass]?.midiNote, 48)  // C3 — 멜로디보다 정확히 1옥타브 아래
        XCTAssertEqual(byInterval[.third]?.midiNote, 52) // E3 — 장3도
        XCTAssertEqual(byInterval[.fifth]?.midiNote, 55) // G3 — 완전5도
    }

    func testVoicesNeverCrossRegardlessOfScaleWrap() throws {
        // G4(MIDI 67) 위에 5도(=D)를 쌓을 때, 베이스와 같은 옥타브 밴드에 그대로 두면 베이스보다
        // 낮아지는(스케일 인덱스가 배열 경계를 넘어가는) 경우 — 옥타브를 올려서라도 베이스보다
        // 위, 멜로디보다 아래 자리를 지켜야 한다("성부 교차 방지").
        let melodyFrequency = NoteNameConverter.frequency(forMIDINote: 67)
        let harmony = try XCTUnwrap(ChordGenerator.generateHarmony(melodyFrequency: melodyFrequency, key: key(tonic: 0, mode: .major)))
        let byInterval = harmonyByInterval(harmony)

        XCTAssertEqual(byInterval[.bass]?.midiNote, 55)  // G3
        XCTAssertEqual(byInterval[.third]?.midiNote, 59) // B3
        XCTAssertEqual(byInterval[.fifth]?.midiNote, 62) // D4 — 옥타브 보정 없인 D3(50)로 베이스보다 낮아짐

        let melodyMIDINote = 67
        XCTAssertLessThan(byInterval[.bass]!.midiNote, byInterval[.third]!.midiNote)
        XCTAssertLessThan(byInterval[.third]!.midiNote, byInterval[.fifth]!.midiNote)
        XCTAssertLessThan(byInterval[.fifth]!.midiNote, melodyMIDINote)
    }

    func testAMinorTriadFromRootMelodyNote() throws {
        // A3(MIDI 57) 위에 A단조 3화음(A-C-E)을 쌓으면 단3도(C)/완전5도(E)가 나와야 한다.
        let melodyFrequency = NoteNameConverter.frequency(forMIDINote: 57)
        let harmony = try XCTUnwrap(ChordGenerator.generateHarmony(melodyFrequency: melodyFrequency, key: key(tonic: 9, mode: .minor)))
        let byInterval = harmonyByInterval(harmony)

        XCTAssertEqual(byInterval[.bass]?.pitchClass, 9)  // A
        XCTAssertEqual(byInterval[.third]?.pitchClass, 0) // C — 단3도
        XCTAssertEqual(byInterval[.fifth]?.pitchClass, 4) // E — 완전5도
    }

    func testBassIsAlwaysExactlyOneOctaveBelowMelody() throws {
        // 스케일의 모든 자리(7개 디그리)를 순회해도 베이스는 항상 "멜로디와 같은 음이름,
        // 정확히 1옥타브 아래"여야 한다 — 스케일 인덱스 wrap 여부와 무관하게 성립해야 하는 불변식.
        for melodyMIDINote in 60...71 { // C4~B4, 한 옥타브 전부
            guard let harmony = ChordGenerator.generateHarmony(
                melodyFrequency: NoteNameConverter.frequency(forMIDINote: melodyMIDINote),
                key: key(tonic: 0, mode: .major)
            ) else { continue } // 온음계 밖 음(반음)은 건너뜀
            let bass = harmonyByInterval(harmony)[.bass]!
            XCTAssertEqual(bass.midiNote, melodyMIDINote - 12, "멜로디 MIDI \(melodyMIDINote)")
            XCTAssertEqual(bass.pitchClass, melodyMIDINote.mod(12))
        }
    }

    func testNonDiatonicMelodyNoteReturnsNil() {
        // C#4는 C장조 온음계에 속하지 않는 반음계 음이라 온음계 화성을 정의할 수 없다.
        let melodyFrequency = NoteNameConverter.frequency(forMIDINote: 61)
        XCTAssertNil(ChordGenerator.generateHarmony(melodyFrequency: melodyFrequency, key: key(tonic: 0, mode: .major)))
    }

    func testInvalidFrequencyReturnsNil() {
        XCTAssertNil(ChordGenerator.generateHarmony(melodyFrequency: 0, key: key(tonic: 0, mode: .major)))
        XCTAssertNil(ChordGenerator.generateHarmony(melodyFrequency: -100, key: key(tonic: 0, mode: .major)))
    }
}
