import XCTest
@testable import Humony

/// 오선 앞머리의 조표(샤프·플랫 개수)를 읽는다 (156절).
///
/// **왜 꼭 읽어야 하는가**: G장조 악보에서 F 자리 음표는 F가 아니라 F#이다. 이건 조옮김
/// 추정으로 못 고친다 — 전체가 밀린 게 아니라 특정 음이름만 반음 다르기 때문이다.
/// 조표를 못 읽으면 그 악보로 교정한 결과가 오히려 채보를 망친다.
final class KeySignatureReaderTests: XCTestCase {

    private let spacing = 14.0
    private let topLineY = 40.0

    private var staff: StaffDetector.Staff {
        StaffDetector.Staff(
            lineYs: (0..<5).map { topLineY + Double($0) * spacing },
            spacing: spacing, minX: 10, maxX: 389
        )
    }

    private func blankPage() -> BinaryImage {
        var image = BinaryImage(width: 400, height: 180)
        for lineY in staff.lineYs {
            for x in staff.minX...staff.maxX {
                image[x, Int(lineY)] = true
            }
        }
        return image
    }

    private func fill(_ image: inout BinaryImage, x: ClosedRange<Int>, y: ClosedRange<Int>) {
        for py in y where py >= 0 && py < image.height {
            for px in x where px >= 0 && px < image.width {
                image[px, py] = true
            }
        }
    }

    /// 샤프: 세로줄 둘 + 가로줄 둘. **위쪽 절반에도 가로로 넓게 퍼져 있다**는 게 플랫과
    /// 갈리는 지점이다.
    private func drawSharp(_ image: inout BinaryImage, centerX: Int, centerY: Double) {
        let height = Int(spacing * 2.2)
        let width = Int(spacing * 0.8)
        let top = Int(centerY) - height / 2
        let thickness = max(1, Int(spacing * 0.12))

        for offset in [width / 4, width * 3 / 4] {
            fill(&image, x: (centerX - width / 2 + offset)...(centerX - width / 2 + offset + thickness),
                 y: top...(top + height))
        }
        for offset in [height / 3, height * 2 / 3] {
            fill(&image, x: (centerX - width / 2)...(centerX + width / 2),
                 y: (top + offset)...(top + offset + thickness))
        }
    }

    /// 플랫: 위로 긴 얇은 줄기 + 아래쪽 볼록한 배. **위쪽 절반은 줄기 하나뿐이라 가로로 좁다.**
    private func drawFlat(_ image: inout BinaryImage, centerX: Int, centerY: Double) {
        let height = Int(spacing * 2.4)
        let top = Int(centerY) - height * 2 / 3
        let thickness = max(1, Int(spacing * 0.12))

        fill(&image, x: centerX...(centerX + thickness), y: top...(top + height))
        // 아래 절반의 배
        let bellyTop = top + height / 2
        for y in bellyTop...(top + height) {
            let progress = Double(y - bellyTop) / Double(height / 2)
            let radius = Int(spacing * 0.55 * sin(progress * Double.pi))
            guard radius > 0 else { continue }
            fill(&image, x: (centerX + thickness)...(centerX + thickness + radius), y: y...y)
        }
    }

    /// 음자리표는 오선 전체보다 크고 두껍다 — 조표로 세면 안 된다.
    private func drawClef(_ image: inout BinaryImage, centerX: Int) {
        fill(&image, x: (centerX - Int(spacing * 0.8))...(centerX + Int(spacing * 0.8)),
             y: Int(topLineY - spacing)...Int(topLineY + spacing * 5))
    }

    // MARK: - 개수와 방향

    func testReadsASingleSharp() {
        var image = blankPage()
        drawClef(&image, centerX: 30)
        drawSharp(&image, centerX: 70, centerY: topLineY)

        XCTAssertEqual(KeySignatureReader.fifths(in: image, staff: staff, beforeX: 200), 1)
    }

    func testReadsThreeSharps() {
        var image = blankPage()
        drawClef(&image, centerX: 30)
        drawSharp(&image, centerX: 70, centerY: topLineY)
        drawSharp(&image, centerX: 90, centerY: topLineY + spacing * 1.5)
        drawSharp(&image, centerX: 110, centerY: topLineY - spacing * 0.5)

        XCTAssertEqual(KeySignatureReader.fifths(in: image, staff: staff, beforeX: 200), 3)
    }

    /// 플랫은 음수다 — 5도권에서 반대 방향이다.
    func testReadsTwoFlatsAsNegative() {
        var image = blankPage()
        drawClef(&image, centerX: 30)
        drawFlat(&image, centerX: 75, centerY: topLineY + spacing)
        drawFlat(&image, centerX: 100, centerY: topLineY + spacing * 2.5)

        XCTAssertEqual(KeySignatureReader.fifths(in: image, staff: staff, beforeX: 200), -2)
    }

    // MARK: - 모를 때는 모른다고 한다

    /// 조표가 없는 악보(C장조/A단조)는 0이다 — **nil이 아니다.** 음자리표만 있고 기호가
    /// 없다는 건 "조표가 없다"는 정보이지 "못 읽었다"가 아니다.
    func testNoAccidentalsMeansZero() {
        var image = blankPage()
        drawClef(&image, centerX: 30)

        XCTAssertEqual(KeySignatureReader.fifths(in: image, staff: staff, beforeX: 200), 0)
    }

    /// 샤프와 플랫이 섞여 나오면 잘못 읽은 것이다 — 실제 조표는 한 종류만 쓴다.
    /// 이때는 **모른다(nil)**고 해야 한다. 155절 계약대로, 모르는 걸 0으로 지어내면
    /// 뒤 단계가 "악보에서 온 확실한 값"으로 믿어버린다.
    func testMixedSymbolsAreReportedAsUnknown() {
        var image = blankPage()
        drawClef(&image, centerX: 30)
        drawSharp(&image, centerX: 70, centerY: topLineY)
        drawFlat(&image, centerX: 100, centerY: topLineY + spacing * 2)

        XCTAssertNil(KeySignatureReader.fifths(in: image, staff: staff, beforeX: 200))
    }

    /// 조표는 최대 일곱이다. 그보다 많이 세었으면 뭔가를 잘못 읽은 것이다.
    func testTooManySymbolsAreReportedAsUnknown() {
        var image = blankPage()
        drawClef(&image, centerX: 30)
        for index in 0..<9 {
            drawSharp(&image, centerX: 60 + index * 18, centerY: topLineY + spacing)
        }

        XCTAssertNil(KeySignatureReader.fifths(in: image, staff: staff, beforeX: 250))
    }

    /// 첫 음표 뒤에 나오는 임시표는 조표가 아니다 — 검색 범위를 첫 머리 앞으로 끊는다.
    func testStopsBeforeTheFirstNotehead() {
        var image = blankPage()
        drawClef(&image, centerX: 30)
        drawSharp(&image, centerX: 70, centerY: topLineY)
        drawSharp(&image, centerX: 250, centerY: topLineY)   // 곡 중간의 임시표

        XCTAssertEqual(KeySignatureReader.fifths(in: image, staff: staff, beforeX: 200), 1)
    }
}
