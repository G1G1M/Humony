import XCTest
@testable import Humony

/// 악보 사진에서 오선(5줄)을 찾는다 — 모든 것의 기준자다 (156절).
///
/// 오선을 찾으면 두 가지가 한꺼번에 정해진다: **음높이의 눈금**(줄 간격이 온음계 두 칸)과
/// **크기 척도**(음표 머리 크기, 조표 기호 크기가 전부 줄 간격의 배수다). 그래서 사진의
/// 해상도나 촬영 거리를 몰라도 나머지 단계가 성립한다.
final class StaffDetectorTests: XCTestCase {

    /// 가로로 꽉 찬 오선 5줄을 그린 이미지.
    private func staffImage(width: Int = 200, height: Int = 100,
                            lineYs: [Int], thickness: Int = 2,
                            margin: Int = 10) -> BinaryImage {
        var image = BinaryImage(width: width, height: height)
        for lineY in lineYs {
            for offset in 0..<thickness {
                for x in margin..<(width - margin) {
                    image[x, lineY + offset] = true
                }
            }
        }
        return image
    }

    func testFindsASingleStaffAndItsSpacing() throws {
        let image = staffImage(lineYs: [20, 30, 40, 50, 60])

        let staves = StaffDetector.detect(in: image)

        XCTAssertEqual(staves.count, 1)
        let staff = try XCTUnwrap(staves.first)
        XCTAssertEqual(staff.lineYs.count, 5)
        XCTAssertEqual(staff.spacing, 10, accuracy: 1.0)
        // 위에서 아래 순서 — 음높이 계산이 이 순서를 전제한다.
        XCTAssertEqual(staff.lineYs, staff.lineYs.sorted())
    }

    /// 한 장에 여러 단(system)이 있는 게 보통이다 — 위에서 아래 순서로 나와야 이어 붙였을 때
    /// 곡의 순서가 된다.
    func testFindsMultipleStavesInReadingOrder() {
        let image = staffImage(height: 200, lineYs: [20, 30, 40, 50, 60, 120, 130, 140, 150, 160])

        let staves = StaffDetector.detect(in: image)

        XCTAssertEqual(staves.count, 2)
        XCTAssertLessThan(staves[0].lineYs[0], staves[1].lineYs[0])
    }

    /// **음표와 줄기가 있어도 오선만 잡아야 한다.** 줄기는 세로로 길지만 가로로는 몇 픽셀뿐이라
    /// 수평 투영에서 봉우리를 만들지 못한다 — 이 성질이 오선을 가려내는 근거다.
    func testIgnoresNotesAndStems() throws {
        var image = staffImage(lineYs: [20, 30, 40, 50, 60])
        // 음표 머리(타원 대신 사각형으로 충분하다) + 줄기
        for y in 36...44 {
            for x in 80...92 { image[x, y] = true }
        }
        for y in 10...40 {
            for x in 92...94 { image[x, y] = true }
        }

        let staves = StaffDetector.detect(in: image)

        XCTAssertEqual(staves.count, 1)
        XCTAssertEqual(try XCTUnwrap(staves.first).lineYs.count, 5)
    }

    /// 오선의 좌우 끝을 알아야 음표를 찾을 가로 범위가 정해진다(페이지 여백에서 헛것을 찾지 않게).
    func testReportsTheHorizontalExtentOfTheStaff() throws {
        let image = staffImage(width: 200, lineYs: [20, 30, 40, 50, 60], margin: 25)

        let staff = try XCTUnwrap(StaffDetector.detect(in: image).first)

        XCTAssertEqual(staff.minX, 25, accuracy: 3)
        XCTAssertEqual(staff.maxX, 174, accuracy: 3)
    }

    /// 줄이 다섯이 아니면 오선이 아니다 — 표 테두리나 밑줄이 그어진 종이를 오선으로 읽으면
    /// 그 뒤 전부가 헛것이 된다.
    func testDoesNotReportGroupsWithFewerThanFiveLines() {
        let image = staffImage(lineYs: [20, 30, 40, 50])

        XCTAssertTrue(StaffDetector.detect(in: image).isEmpty)
    }

    /// 간격이 제각각이면 오선이 아니다(문단 밑줄, 표 등).
    func testRejectsLinesWithIrregularSpacing() {
        let image = staffImage(lineYs: [10, 30, 35, 70, 90])

        XCTAssertTrue(StaffDetector.detect(in: image).isEmpty)
    }

    func testEmptyImageHasNoStaves() {
        XCTAssertTrue(StaffDetector.detect(in: BinaryImage(width: 50, height: 50)).isEmpty)
    }
}
