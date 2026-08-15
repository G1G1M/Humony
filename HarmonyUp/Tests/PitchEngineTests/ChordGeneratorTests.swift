import XCTest
@testable import HarmonyUp

final class ChordGeneratorTests: XCTestCase {

    private func key(tonic: Int, mode: KeyDetector.Mode) -> KeyDetector.DetectedKey {
        KeyDetector.DetectedKey(tonicPitchClass: tonic, mode: mode, confidence: 1.0)
    }

    func testCMajorTriadFromRootMelodyNote() throws {
        // C4 (MIDI 60) 위에 3도/5도를 쌓으면 C장조 3화음(C-E-G)이 나와야 한다.
        let melodyFrequency = NoteNameConverter.frequency(forMIDINote: 60)
        let harmony = try XCTUnwrap(ChordGenerator.generateHarmony(melodyFrequency: melodyFrequency, key: key(tonic: 0, mode: .major)))

        XCTAssertEqual(harmony.count, 2)
        XCTAssertEqual(harmony[0].midiNote, 64) // E4 — 장3도 위
        XCTAssertEqual(harmony[1].midiNote, 67) // G4 — 완전5도 위
    }

    func testHarmonyIsAlwaysAboveMelodyEvenWhenScaleWraps() throws {
        // G4(MIDI 67) 위에 5도(=D)를 쌓으면, 같은 옥타브의 D(62)는 멜로디보다 낮으므로
        // 한 옥타브 올린 D5(74)가 나와야 한다 — "화음은 항상 멜로디 위로 쌓는다"는 규칙 검증.
        let melodyFrequency = NoteNameConverter.frequency(forMIDINote: 67)
        let harmony = try XCTUnwrap(ChordGenerator.generateHarmony(melodyFrequency: melodyFrequency, key: key(tonic: 0, mode: .major)))

        XCTAssertEqual(harmony[0].midiNote, 71) // B4 — 3도 위
        XCTAssertEqual(harmony[1].midiNote, 74) // D5 — 5도 위, 옥타브 보정됨
        XCTAssertTrue(harmony.allSatisfy { $0.midiNote > 67 })
    }

    func testAMinorTriadFromRootMelodyNote() throws {
        // A3(MIDI 57) 위에 A단조 3도/5도를 쌓으면 A단조 3화음(A-C-E)이 나와야 한다.
        let melodyFrequency = NoteNameConverter.frequency(forMIDINote: 57)
        let harmony = try XCTUnwrap(ChordGenerator.generateHarmony(melodyFrequency: melodyFrequency, key: key(tonic: 9, mode: .minor)))

        XCTAssertEqual(harmony[0].pitchClass, 0)  // C — 단3도 위
        XCTAssertEqual(harmony[1].pitchClass, 4)  // E — 완전5도 위
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
