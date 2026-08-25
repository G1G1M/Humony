import XCTest
@testable import Humony

/// 오선을 지운 뒤 남은 것에서 음표 머리를 찾는다 (156절).
///
/// **왜 머리만 찾는가**: 이 앱은 악보에서 **음높이 순서**만 필요하다 — 리듬은 실제로 부른
/// 그대로 쓰기 때문이다(155절). OMR에서 가장 어려운 박자·음가 해석을 통째로 건너뛸 수 있고,
/// 남는 건 "타원이 어디 있나"라는 훨씬 단순한 문제다.
final class NoteheadDetectorTests: XCTestCase {

    private let spacing = 12.0
    private let topLineY = 30.0

    private var staff: StaffDetector.Staff {
        StaffDetector.Staff(
            lineYs: (0..<5).map { topLineY + Double($0) * spacing },
            spacing: spacing,
            minX: 10,
            maxX: 289
        )
    }

    private func blankPage(width: Int = 300, height: Int = 140) -> BinaryImage {
        var image = BinaryImage(width: width, height: height)
        for lineY in staff.lineYs {
            for x in staff.minX...staff.maxX {
                image[x, Int(lineY)] = true
                image[x, Int(lineY) + 1] = true
            }
        }
        return image
    }

    /// 음표 머리는 살짝 기운 타원이지만, 검출은 "크기와 채움"만 보므로 곧은 타원으로 충분하다.
    private func drawNotehead(_ image: inout BinaryImage, centerX: Int, centerY: Double,
                              filled: Bool = true, stem: Bool = true) {
        let radiusX = spacing * 0.62
        let radiusY = spacing * 0.48

        var y = centerY - radiusY - 1
        while y <= centerY + radiusY + 1 {
            var x = Double(centerX) - radiusX - 1
            while x <= Double(centerX) + radiusX + 1 {
                let normalized = pow((x - Double(centerX)) / radiusX, 2) + pow((y - centerY) / radiusY, 2)
                if normalized <= 1.0 {
                    // 빈 머리(2분·온음표)는 테두리만 그린다 — 안쪽이 뚫려 있다.
                    let isInnerHole = normalized <= 0.35
                    if filled || !isInnerHole { image[Int(x), Int(y)] = true }
                }
                x += 1
            }
            y += 1
        }

        if stem {
            let stemX = centerX + Int(radiusX)
            for y in Int(centerY - spacing * 3.2)...Int(centerY) {
                image[stemX, y] = true
                image[stemX + 1, y] = true
            }
        }
    }

    // MARK: - 검출

    func testFindsFilledNoteheadsInLeftToRightOrder() {
        var image = blankPage()
        drawNotehead(&image, centerX: 60, centerY: topLineY + spacing * 4)      // 맨 아래 줄
        drawNotehead(&image, centerX: 120, centerY: topLineY + spacing * 3)
        drawNotehead(&image, centerX: 180, centerY: topLineY + spacing * 2)     // 가운데 줄

        let heads = NoteheadDetector.detect(in: image, staff: staff)

        XCTAssertEqual(heads.count, 3)
        XCTAssertEqual(heads.map(\.x), heads.map(\.x).sorted())
        XCTAssertEqual(heads[0].x, 60, accuracy: spacing * 0.5)
        XCTAssertEqual(heads[0].y, topLineY + spacing * 4, accuracy: spacing * 0.4)
    }

    /// 칸(줄 사이)에 놓인 음표도 똑같이 잡아야 한다 — 줄 위와 칸이 번갈아 한 계단씩이다.
    func testFindsNoteheadsInSpacesBetweenLines() {
        var image = blankPage()
        drawNotehead(&image, centerX: 80, centerY: topLineY + spacing * 3.5)

        let heads = NoteheadDetector.detect(in: image, staff: staff)

        XCTAssertEqual(heads.count, 1)
        XCTAssertEqual(heads[0].y, topLineY + spacing * 3.5, accuracy: spacing * 0.4)
    }

    /// **빈 머리(2분·온음표)도 찾아야 한다.** 안이 뚫려 있어 잉크 비율이 낮으므로, 검출 전에
    /// 구멍을 메워 채워진 머리와 같은 모양으로 만든 뒤 본다.
    func testFindsHollowNoteheads() {
        var image = blankPage()
        drawNotehead(&image, centerX: 90, centerY: topLineY + spacing * 2, filled: false)

        let heads = NoteheadDetector.detect(in: image, staff: staff)

        XCTAssertEqual(heads.count, 1)
        XCTAssertEqual(heads[0].y, topLineY + spacing * 2, accuracy: spacing * 0.4)
    }

    /// 오선 밖(덧줄 자리)의 음도 놓치면 안 된다 — 멜로디는 오선을 자주 벗어난다.
    func testFindsNoteheadsAboveAndBelowTheStaff() {
        var image = blankPage()
        drawNotehead(&image, centerX: 70, centerY: topLineY - spacing, stem: false)
        drawNotehead(&image, centerX: 150, centerY: topLineY + spacing * 5, stem: false)

        let heads = NoteheadDetector.detect(in: image, staff: staff)

        XCTAssertEqual(heads.count, 2)
    }

    /// 줄기만 있고 머리가 없으면 음표가 아니다 — 마디선·세로줄을 음표로 읽으면 안 된다.
    func testIgnoresBareVerticalLines() {
        var image = blankPage()
        for y in Int(topLineY)...Int(topLineY + spacing * 4) {
            image[200, y] = true
            image[201, y] = true
        }

        XCTAssertTrue(NoteheadDetector.detect(in: image, staff: staff).isEmpty)
    }

    /// 오선만 있는 빈 악보에서는 아무것도 안 나와야 한다 — 오선 자체를 머리로 읽으면
    /// 온 페이지가 음표로 뒤덮인다.
    func testEmptyStaffHasNoNoteheads() {
        let image = blankPage()

        XCTAssertTrue(NoteheadDetector.detect(in: image, staff: staff).isEmpty)
    }
}
