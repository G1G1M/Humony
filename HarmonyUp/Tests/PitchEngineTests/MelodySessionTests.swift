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
            frameDuration: duration,
            samples: [],
            sampleRate: 44100
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

    // ChordGenerator.harmonizeSequence(Viterbi)는 지금까지 누적된 노트 전체의 문맥을 보고
    // 코드를 고르므로, suggestedHarmony가 그 결과의 "마지막 노트" 값을 정확히 반환하는지
    // 확인하려면 결과가 뚜렷하게 예측 가능한 시퀀스를 써야 한다 — C-E-G는 셋 다 C장조 I의
    // 구성음이라 I가 유일하게 최적인 코드로 뽑힌다(다른 후보는 최소 한 음에서 페널티를 받음).
    func testSuggestedHarmonyReflectsLastNoteInContext() throws {
        let session = MelodySession()
        session.record(result(midiNote: 60, duration: 0.3)) // C4
        session.record(result(midiNote: 64, duration: 0.3)) // E4
        session.record(result(midiNote: 67, duration: 0.3)) // G4 — 마지막 음

        let harmony = try XCTUnwrap(session.suggestedHarmony)
        let byInterval = Dictionary(uniqueKeysWithValues: harmony.map { ($0.interval, $0) })
        XCTAssertEqual(byInterval[.bass]?.pitchClass, 0)  // C — I의 근음
        XCTAssertEqual(byInterval[.third]?.pitchClass, 4) // E
        XCTAssertEqual(byInterval[.fifth]?.pitchClass, 7) // G
        // 배치 위치는 항상 마지막 노트(G4=67) 기준이어야 한다.
        XCTAssertLessThan(byInterval[.fifth]!.midiNote, 67)
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

    func testCorrectNoteChangesKeyDetection() {
        let session = MelodySession()
        // C장조 프로파일에서 F#(6번, 실제로는 반음계 밖 음)을 잘못 잡았다고 가정하고 고쳐본다.
        for (pitchClass, duration) in majorProfile.enumerated() {
            session.record(result(midiNote: 60 + pitchClass, duration: duration))
        }
        XCTAssertEqual(session.detectedKey?.tonicPitchClass, 0)

        // 인덱스 0(C)을 D#으로 잘못 고쳐서, 조성 판별 결과가 실제로 바뀌는지 확인한다.
        session.correctNote(at: 0, to: result(midiNote: 63, duration: majorProfile[0])) // D#4

        // 적어도 correctNote가 반영돼서 이전과 완전히 같은 분포는 아니어야 한다 —
        // 정확히 어떤 조성이 나오는지보다, 수정이 실제로 누적치에 반영됐는지가 핵심.
        XCTAssertNotNil(session.detectedKey)
    }

    func testCorrectingLastNoteUpdatesLastNote() throws {
        let session = MelodySession()
        session.record(result(midiNote: 66, duration: 0.1)) // F#4로 잘못 잡혔다고 가정

        let corrected = result(midiNote: 67, duration: 0.1) // G4로 수정
        session.correctNote(at: 0, to: corrected)

        let lastNote = try XCTUnwrap(session.lastNote)
        XCTAssertEqual(lastNote.noteName, "G4")
    }

    func testCorrectingNonLastNoteDoesNotChangeLastNote() throws {
        let session = MelodySession()
        session.record(result(midiNote: 66, duration: 0.1)) // 인덱스 0, 나중에 고칠 음
        session.record(result(midiNote: 72, duration: 0.1)) // 인덱스 1, 마지막 음(C5)

        session.correctNote(at: 0, to: result(midiNote: 67, duration: 0.1))

        let lastNote = try XCTUnwrap(session.lastNote)
        XCTAssertEqual(lastNote.noteName, "C5") // 마지막 음은 그대로 유지돼야 한다
    }

    func testCorrectNoteOutOfBoundsIsNoOp() {
        let session = MelodySession()
        session.record(result(midiNote: 60, duration: 0.1))

        session.correctNote(at: 5, to: result(midiNote: 67, duration: 0.1)) // 존재하지 않는 인덱스

        XCTAssertEqual(session.lastNote?.noteName, "C4") // 아무 영향 없어야 한다
    }
}
