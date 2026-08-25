import XCTest
@testable import Humony

/// 음표 머리의 세로 위치를 음높이로 옮긴다 (156절).
///
/// 오선에서 **줄과 칸이 번갈아 온음계 한 계단**이다. 그래서 필요한 건 줄 간격 하나뿐이고,
/// 사진의 해상도나 촬영 거리는 알 필요가 없다.
final class StaffPitchMapperTests: XCTestCase {

    private let spacing = 12.0

    /// 위에서 아래로 5줄. 맨 아래 줄이 높은음자리표의 E4다.
    private var staff: StaffDetector.Staff {
        StaffDetector.Staff(
            lineYs: (0..<5).map { 30.0 + Double($0) * spacing },
            spacing: spacing, minX: 0, maxX: 100
        )
    }

    private func step(atY y: Double) -> Int {
        StaffPitchMapper.diatonicStep(y: y, staff: staff)
    }

    private func midi(step: Int, clef: StaffPitchMapper.Clef = .treble, fifths: Int = 0) -> Int {
        StaffPitchMapper.midiNote(diatonicStep: step, clef: clef, fifths: fifths)
    }

    // MARK: - 세로 위치 → 계단

    func testBottomLineIsStepZeroAndEachHalfSpaceIsOneStep() {
        let bottomLineY = staff.lineYs[4]

        XCTAssertEqual(step(atY: bottomLineY), 0)
        XCTAssertEqual(step(atY: bottomLineY - spacing / 2), 1)   // 바로 위 칸
        XCTAssertEqual(step(atY: bottomLineY - spacing), 2)       // 그 위 줄
        XCTAssertEqual(step(atY: staff.lineYs[0]), 8)             // 맨 위 줄
    }

    /// 오선 밖(덧줄 자리)은 음수 계단이다 — 멜로디는 오선을 자주 벗어난다.
    func testStepsBelowTheStaffAreNegative() {
        XCTAssertEqual(step(atY: staff.lineYs[4] + spacing), -2)
    }

    /// 검출된 머리 좌표는 픽셀 단위로 조금씩 어긋난다 — 가장 가까운 계단으로 붙인다.
    func testRoundsToTheNearestStep() {
        let bottomLineY = staff.lineYs[4]

        XCTAssertEqual(step(atY: bottomLineY - 1), 0)              // 아직 줄 위
        XCTAssertEqual(step(atY: bottomLineY - spacing / 2 + 1), 1) // 칸 쪽에 가깝다
    }

    // MARK: - 계단 → 음높이

    /// 높은음자리표의 다섯 줄: 아래에서 E4 G4 B4 D5 F5("미 솔 시 레 파").
    func testTrebleClefLines() {
        XCTAssertEqual(midi(step: 0), 64)   // E4
        XCTAssertEqual(midi(step: 2), 67)   // G4
        XCTAssertEqual(midi(step: 4), 71)   // B4
        XCTAssertEqual(midi(step: 6), 74)   // D5
        XCTAssertEqual(midi(step: 8), 77)   // F5
    }

    /// 칸은 아래에서 F4 A4 C5 E5("파 라 도 미").
    func testTrebleClefSpaces() {
        XCTAssertEqual(midi(step: 1), 65)   // F4
        XCTAssertEqual(midi(step: 3), 69)   // A4
        XCTAssertEqual(midi(step: 5), 72)   // C5
        XCTAssertEqual(midi(step: 7), 76)   // E5
    }

    /// 오선 아래 첫 덧줄이 가온다(C4)다.
    func testMiddleCSitsOnTheFirstLedgerLineBelowTheTrebleStaff() {
        XCTAssertEqual(midi(step: -2), 60)
    }

    func testBassClefLines() {
        XCTAssertEqual(midi(step: 0, clef: .bass), 43)   // G2
        XCTAssertEqual(midi(step: 8, clef: .bass), 57)   // A3
    }

    // MARK: - 조표

    /// **조표를 안 읽으면 음이 틀린다.** G장조에서 F 자리 음표는 F가 아니라 F#이다 —
    /// 조옮김 추정으로는 못 고친다(전체가 밀린 게 아니라 특정 음만 반음 다르다).
    func testSharpKeySignatureRaisesTheAffectedLetters() {
        XCTAssertEqual(midi(step: 1, fifths: 1), 66)    // F4 → F#4 (G장조)
        XCTAssertEqual(midi(step: 0, fifths: 1), 64)    // E4는 그대로
        XCTAssertEqual(midi(step: 5, fifths: 2), 73)    // C5 → C#5 (D장조)
    }

    func testFlatKeySignatureLowersTheAffectedLetters() {
        XCTAssertEqual(midi(step: 4, fifths: -1), 70)   // B4 → Bb4 (F장조)
        XCTAssertEqual(midi(step: 7, fifths: -2), 75)   // E5 → Eb5 (Bb장조)
        XCTAssertEqual(midi(step: 0, fifths: -1), 64)   // E4는 그대로
    }

    /// 같은 음이름은 옥타브가 달라도 함께 변한다 — 조표는 음이름에 붙는 규칙이다.
    func testKeySignatureAppliesToEveryOctave() {
        XCTAssertEqual(midi(step: 1, fifths: 1), 66)    // F4#
        XCTAssertEqual(midi(step: 8, fifths: 1), 78)    // F5#
    }
}
