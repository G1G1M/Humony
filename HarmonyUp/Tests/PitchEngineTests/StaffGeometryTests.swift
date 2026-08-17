import XCTest
@testable import HarmonyUp

final class StaffGeometryTests: XCTestCase {

    // 트레블(높은음자리표) 5선: 아래부터 E4 G4 B4 D5 F5. 줄 간격 10pt, 첫 줄 y=100으로 두고
    // 위로 갈수록(음이 높아질수록) y가 작아지는지 확인한다.
    private let treble = StaffGeometry(clef: .treble, lineSpacing: 10, bottomLineY: 100)
    private let bass = StaffGeometry(clef: .bass, lineSpacing: 10, bottomLineY: 100)

    func testTrebleBottomLineIsE4() {
        let position = treble.position(for: 64) // E4
        XCTAssertEqual(position.y, 100, accuracy: 0.01)
        XCTAssertFalse(position.needsSharp)
        XCTAssertTrue(position.ledgerLineYs.isEmpty)
    }

    func testTrebleTopLineIsF5() {
        // E4(0칸)부터 줄만 5개(E G B D F)면 8칸 위가 top line — 반음간격 아니라 다이어토닉
        // 레터 기준이라 4개 자연음(G B D F)을 지나야 함 = 8칸(줄 간 2칸씩).
        let position = treble.position(for: 77) // F5
        XCTAssertEqual(position.y, 100 - 8 * 5, accuracy: 0.01) // 8칸 * (lineSpacing/2)
        XCTAssertTrue(position.ledgerLineYs.isEmpty)
    }

    // 미들 C(C4)는 트레블 오선 바로 아래, 덧줄 하나가 필요한 대표적인 음 — 실제 악보에서도
    // 가장 잘 알려진 덧줄 예시라 이걸로 정확성을 확인한다.
    func testMiddleCNeedsExactlyOneLedgerLineBelowTreble() {
        let position = treble.position(for: 60) // C4
        XCTAssertEqual(position.ledgerLineYs.count, 1)
        XCTAssertFalse(position.needsSharp)
        XCTAssertGreaterThan(position.y, 100) // 첫 줄보다 아래(y값 더 큼)
    }

    func testSharpNoteSharesPositionWithNaturalBelow() {
        let cSharp = treble.position(for: 61) // C#4
        let c = treble.position(for: 60) // C4
        XCTAssertEqual(cSharp.y, c.y, accuracy: 0.01, "C#4는 C4와 정확히 같은 자리에 그려지고 샵만 붙어야 함")
        XCTAssertTrue(cSharp.needsSharp)
    }

    func testHigherPitchAlwaysHasSmallerYWithinSameClef() {
        // 다이어토닉 레터가 다른 두 음(반음 관계 아님)을 비교 — 음이 높을수록 화면에서 위(y 작음).
        let low = treble.position(for: 62) // D4
        let high = treble.position(for: 74) // D5
        XCTAssertLessThan(high.y, low.y)
    }

    func testBassBottomLineIsG2() {
        let position = bass.position(for: 43) // G2
        XCTAssertEqual(position.y, 100, accuracy: 0.01)
        XCTAssertFalse(position.needsSharp)
    }

    func testNoteFarBelowStaffGetsMultipleLedgerLines() {
        // 트레블 기준 A3(미들 C보다 한 다이어토닉 칸 더 아래)는 덧줄 2개가 필요하다.
        let position = treble.position(for: 57) // A3
        XCTAssertEqual(position.ledgerLineYs.count, 2)
    }

    func testDiatonicIndexIsMonotonicWithPitch() {
        // 다이어토닉 인덱스는 음이 높아질수록 항상 증가(또는 최소 감소하지 않음)해야 한다 —
        // 화면 배치가 거꾸로 뒤집히는 회귀를 잡는다.
        var previous = StaffGeometry.diatonicIndex(for: 48).index
        for midiNote in 49...84 {
            let current = StaffGeometry.diatonicIndex(for: midiNote).index
            XCTAssertGreaterThanOrEqual(current, previous, "MIDI \(midiNote)")
            previous = current
        }
    }
}
