import XCTest
@testable import HarmonyUp

final class MelodySessionTests: XCTestCase {

    private func result(midiNote: Int, duration: Double) -> AudioCapture.DetectionResult {
        let frequency = NoteNameConverter.frequency(forMIDINote: midiNote)
        let note = NoteNameConverter.convert(frequency: frequency)!
        return AudioCapture.DetectionResult(
            frequency: frequency,
            noteName: note.noteName,
            centsOffset: note.centsOffset,
            confidence: 0.99,
            pitchClass: note.pitchClass,
            frameDuration: duration
        )
    }

    // Temperley 장조 프로파일 값을 그대로 "각 음을 그만큼 오래 불렀다"는 프레임으로 재생해서
    // MelodySession이 KeyDetector가 기대하는 입력 형태로 정확히 누적하는지 확인한다.
    private let majorProfile: [Double] = [5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0]

    func testAccumulatesKeyFromMultipleFrames() {
        let session = MelodySession()
        for (pitchClass, duration) in majorProfile.enumerated() {
            session.record(result(midiNote: 60 + pitchClass, duration: duration))
        }

        XCTAssertEqual(session.detectedKey?.tonicPitchClass, 0)
        XCTAssertEqual(session.detectedKey?.mode, .major)
    }

    func testNilFramesAreIgnored() {
        let session = MelodySession()
        for (pitchClass, duration) in majorProfile.enumerated() {
            session.record(result(midiNote: 60 + pitchClass, duration: duration))
            session.record(nil) // 무음 프레임 — 조성 판단에 영향을 주면 안 된다
        }

        XCTAssertEqual(session.detectedKey?.tonicPitchClass, 0)
        XCTAssertEqual(session.detectedKey?.mode, .major)
    }

    func testSuggestedHarmonyUsesLastNoteAboveDetectedKey() throws {
        let session = MelodySession()
        for (pitchClass, duration) in majorProfile.enumerated() {
            session.record(result(midiNote: 60 + pitchClass, duration: duration))
        }
        session.record(result(midiNote: 60, duration: 0.05)) // 마지막으로 부른 음 = C4

        let harmony = try XCTUnwrap(session.suggestedHarmony)
        XCTAssertEqual(harmony[0].midiNote, 64) // E4
        XCTAssertEqual(harmony[1].midiNote, 67) // G4
    }

    func testEmptySessionHasNoKeyOrHarmony() {
        let session = MelodySession()
        XCTAssertNil(session.detectedKey)
        XCTAssertNil(session.suggestedHarmony)
    }

    func testResetClearsAccumulatedState() {
        let session = MelodySession()
        session.record(result(midiNote: 60, duration: 5.0))
        XCTAssertNotNil(session.detectedKey)

        session.reset()

        XCTAssertNil(session.detectedKey)
        XCTAssertNil(session.lastNote)
    }
}
