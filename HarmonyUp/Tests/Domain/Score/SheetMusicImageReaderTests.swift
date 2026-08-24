import XCTest
@testable import HarmonyUp

/// 악보 사진 한 장을 음 목록으로 (156절) — 오선·머리·조표 세 조각을 묶는 마지막 단계.
final class SheetMusicImageReaderTests: XCTestCase {

    private let spacing = 14.0

    /// 오선 한 단과 음표들을 그린 합성 악보.
    private func page(staffTops: [Double], notesPerStaff: [[(x: Int, step: Int)]],
                      width: Int = 400, height: Int = 260) -> BinaryImage {
        var image = BinaryImage(width: width, height: height)

        for (staffIndex, top) in staffTops.enumerated() {
            let lineYs = (0..<5).map { top + Double($0) * spacing }
            for lineY in lineYs {
                for x in 20..<(width - 20) { image[x, Int(lineY)] = true }
            }

            let bottomLineY = lineYs[4]
            for note in notesPerStaff[staffIndex] {
                let centerY = bottomLineY - Double(note.step) * spacing / 2
                drawNotehead(&image, centerX: note.x, centerY: centerY)
            }
        }
        return image
    }

    private func drawNotehead(_ image: inout BinaryImage, centerX: Int, centerY: Double) {
        let radiusX = spacing * 0.62
        let radiusY = spacing * 0.48
        var y = centerY - radiusY
        while y <= centerY + radiusY {
            var x = Double(centerX) - radiusX
            while x <= Double(centerX) + radiusX {
                if pow((x - Double(centerX)) / radiusX, 2) + pow((y - centerY) / radiusY, 2) <= 1.0 {
                    image[Int(x), Int(y)] = true
                }
                x += 1
            }
            y += 1
        }
        let stemX = centerX + Int(radiusX)
        for y in Int(centerY - spacing * 3)...Int(centerY) {
            image[stemX, y] = true
            image[stemX + 1, y] = true
        }
    }

    // MARK: - 읽기

    /// 도-레-미-파-솔을 그려놓고 그대로 읽어오는지 — 이 테스트가 통과하면 오선·머리·음높이가
    /// 한 줄로 이어진 것이다.
    func testReadsAScaleFromASingleStaff() throws {
        // 높은음자리표: 계단 -2 = C4(60), 이후 온음계로 D E F G
        let image = page(staffTops: [40], notesPerStaff: [[
            (x: 80, step: -2), (x: 130, step: -1), (x: 180, step: 0), (x: 230, step: 1), (x: 280, step: 2)
        ]])

        let score = try SheetMusicImageReader.read(binary: image)

        XCTAssertEqual(score.notes.map(\.midiNote), [60, 62, 64, 65, 67])
    }

    /// 단(system)이 여럿이면 **위에서 아래로** 이어 붙여야 곡의 순서가 된다.
    func testReadsMultipleStavesInReadingOrder() throws {
        let image = page(
            staffTops: [40, 160],
            notesPerStaff: [
                [(x: 80, step: 0), (x: 160, step: 2)],
                [(x: 80, step: 4), (x: 160, step: 6)]
            ]
        )

        let score = try SheetMusicImageReader.read(binary: image)

        XCTAssertEqual(score.notes.map(\.midiNote), [64, 67, 71, 74])
    }

    /// 길이는 알 수 없다 — 리듬은 부른 그대로 쓰므로(155절) 모두 같은 값을 준다.
    /// **모르는 걸 지어내지 않는다**는 뜻이기도 하다.
    func testAllNotesGetTheSameNominalDuration() throws {
        let image = page(staffTops: [40], notesPerStaff: [[(x: 80, step: 0), (x: 160, step: 2)]])

        let score = try SheetMusicImageReader.read(binary: image)

        XCTAssertEqual(Set(score.notes.map(\.duration)).count, 1)
    }

    // MARK: - 읽지 못할 때

    /// 오선이 없으면 악보가 아니다 — 풍경 사진을 넣었을 때 조용히 빈 악보를 주면 뒤 단계가
    /// "악보가 붙었다"고 믿는다.
    func testThrowsWhenThereIsNoStaff() {
        let blank = BinaryImage(width: 200, height: 200)

        XCTAssertThrowsError(try SheetMusicImageReader.read(binary: blank)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .noStaffFound)
        }
    }

    /// 오선은 있는데 음표가 하나도 없는 경우(빈 오선지).
    func testThrowsWhenTheStaffHasNoNotes() {
        let image = page(staffTops: [40], notesPerStaff: [[]])

        XCTAssertThrowsError(try SheetMusicImageReader.read(binary: image)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .noNotesFound)
        }
    }
}
