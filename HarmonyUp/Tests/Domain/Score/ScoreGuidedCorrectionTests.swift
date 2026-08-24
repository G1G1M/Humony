import XCTest
@testable import HarmonyUp

/// 악보가 붙었을 때의 한 걸음 — 조옮김 추정 → 정렬·교정 → 조성 결정을 묶는다 (155절).
/// 오디오 없이 테스트할 수 있도록 파이프라인(`RecordingAnalyzer`)에서 떼어낸 순수 함수다.
final class ScoreGuidedCorrectionTests: XCTestCase {

    private func sung(_ midiNote: Int, onset: Double, duration: Double = 0.5) -> MelodySegmenter.SegmentedNote {
        MelodySegmenter.SegmentedNote(
            midiNote: midiNote, onsetTime: onset, duration: duration, averageConfidence: 0.9
        )
    }

    /// C장조 도레미파솔 악보.
    private func cMajorScore(fifths: Int? = 0, mode: KeyDetector.Mode? = .major) -> ScoreImporter.ImportedScore {
        ScoreImporter.ImportedScore(
            notes: [60, 62, 64, 65, 67].map { PitchedNote(midiNote: $0, duration: 1.0) },
            keyFifths: fifths,
            keyMode: mode
        )
    }

    // MARK: - 교정이 적용되는 경우

    /// 악보와 같은 키로 부르고 한 음만 반음 흔들린 경우 — 그 음만 악보 값으로 돌아온다.
    func testSnapsAStrayNoteBackToTheScore() throws {
        let outcome = ScoreGuidedCorrection.apply(
            sung: [sung(60, onset: 0), sung(63, onset: 1), sung(64, onset: 2), sung(65, onset: 3), sung(67, onset: 4)],
            reference: cMajorScore()
        )

        XCTAssertTrue(outcome.comparison.isApplied)
        XCTAssertEqual(outcome.notes.map(\.midiNote), [60, 62, 64, 65, 67])
        XCTAssertEqual(outcome.comparison.transposition, 0)
    }

    /// **조옮김이 함께 동작해야 한다** — 악보보다 7반음 높게 불렀으면 악보 음을 7반음 올린
    /// 값으로 스냅한다. 악보의 절대 음높이로 끌어내리면 부른 노래가 통째로 딴 키가 된다.
    func testAppliesTranspositionBeforeSnapping() throws {
        let sungNotes = [67, 69, 71, 72, 74].enumerated().map { sung($1, onset: Double($0)) }

        let outcome = ScoreGuidedCorrection.apply(sung: sungNotes, reference: cMajorScore())

        XCTAssertEqual(outcome.comparison.transposition, 7)
        XCTAssertEqual(outcome.notes.map(\.midiNote), [67, 69, 71, 72, 74])
    }

    /// 조성은 **악보 조표 + 조옮김**이다. 152절의 "조성이 반음 위로 뒤집힘"은 낮은 진폭에서
    /// pitch-class 분포가 번져 생긴 문제였는데, 조표가 있으면 그 추정 자체를 건너뛴다.
    func testKeyComesFromTheScoreSignatureShiftedByTheTransposition() throws {
        let sungNotes = [67, 69, 71, 72, 74].enumerated().map { sung($1, onset: Double($0)) }

        let outcome = ScoreGuidedCorrection.apply(sung: sungNotes, reference: cMajorScore())
        let key = try XCTUnwrap(outcome.key)

        XCTAssertEqual(key.tonicPitchClass, 7)   // C장조를 7반음 올려 부름 → G장조
        XCTAssertEqual(key.mode, .major)
        XCTAssertEqual(key.confidence, 1.0)
    }

    /// 악보에 조표가 없으면 조성을 지어내지 않고 nil을 준다 — 호출부가 기존 조성 판별로 간다.
    func testKeyIsNilWhenTheScoreHasNoSignature() {
        let sungNotes = [60, 62, 64, 65, 67].enumerated().map { sung($1, onset: Double($0)) }

        let outcome = ScoreGuidedCorrection.apply(
            sung: sungNotes,
            reference: cMajorScore(fifths: nil, mode: nil)
        )

        XCTAssertNil(outcome.key)
        XCTAssertTrue(outcome.comparison.isApplied)   // 교정 자체는 된다
    }

    // MARK: - 포기하는 경우

    /// 다른 노래를 불렀거나 악보를 잘못 올린 경우 — **부른 그대로 두고 넘어간다.** 억지로
    /// 맞추면 멀쩡한 채보를 악보 쪽으로 끌고 가 더 망가진다(149절 회귀와 같은 종류의 위험).
    func testGivesUpWhenTheSungMelodyDoesNotMatchTheScore() {
        let chromatic = (60...71).enumerated().map { sung($1, onset: Double($0)) }

        let outcome = ScoreGuidedCorrection.apply(sung: chromatic, reference: cMajorScore())

        XCTAssertFalse(outcome.comparison.isApplied)
        XCTAssertEqual(outcome.notes.map(\.midiNote), chromatic.map(\.midiNote))
        XCTAssertNil(outcome.key)   // 조성도 악보 것을 쓰지 않는다 — 맞는 악보인지 모른다
    }

    /// 비교 화면이 "부른 대로 / 교정 후"를 나란히 보여주려면 원본이 남아 있어야 한다.
    func testKeepsTheOriginalNotesForComparison() {
        let sungNotes = [60, 63, 64, 65, 67].enumerated().map { sung($1, onset: Double($0)) }

        let outcome = ScoreGuidedCorrection.apply(sung: sungNotes, reference: cMajorScore())

        XCTAssertEqual(outcome.comparison.notesBeforeCorrection.map(\.midiNote), [60, 63, 64, 65, 67])
        XCTAssertNotEqual(outcome.notes.map(\.midiNote), outcome.comparison.notesBeforeCorrection.map(\.midiNote))
    }

    func testEmptyRecordingIsNotCorrected() {
        let outcome = ScoreGuidedCorrection.apply(sung: [], reference: cMajorScore())

        XCTAssertFalse(outcome.comparison.isApplied)
        XCTAssertTrue(outcome.notes.isEmpty)
    }
}
