import XCTest
import CoreGraphics
@testable import Humony

/// 사진을 악보 읽기가 다룰 수 있는 흑백 비트맵으로 바꾼다 (156절).
///
/// 사진을 스캔본과 다르게 만드는 건 두 가지다 — **고르지 않은 조명**과 **기울어짐**.
final class SheetMusicImagePreprocessorTests: XCTestCase {

    /// 왼쪽은 밝고 오른쪽은 어두운(그림자 진) 종이에 가로선을 그린 그레이스케일.
    private func unevenlyLitPage(width: Int, height: Int, lineYs: [Int]) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // 배경 밝기가 가로로 235 → 90까지 떨어진다(그림자).
                let background = 235.0 - 145.0 * Double(x) / Double(width)
                // 선은 그 자리 배경보다 확실히 어둡다(잉크).
                let isLine = lineYs.contains(y)
                pixels[y * width + x] = UInt8(max(0, isLine ? background * 0.45 : background))
            }
        }
        return pixels
    }

    /// **전역 임계값이 사진에서 실패하는 지점이다.** 그림자 진 쪽 배경이 밝은 쪽 잉크보다
    /// 어두우므로, 밝기 하나로 자르면 그림자 영역이 통째로 잉크가 된다.
    func testLocalThresholdFindsLinesEvenUnderUnevenLighting() {
        let width = 240, height = 80
        let lineYs = [20, 30, 40, 50, 60]
        let gray = unevenlyLitPage(width: width, height: height, lineYs: lineYs)

        let image = SheetMusicImagePreprocessor.binarize(gray: gray, width: width, height: height)

        // 밝은 쪽과 어두운 쪽 양쪽에서 선이 잡혀야 한다.
        XCTAssertTrue(image[20, 30], "밝은 쪽 선을 놓쳤다")
        XCTAssertTrue(image[width - 20, 30], "그림자 쪽 선을 놓쳤다")
        // 선이 아닌 자리는 밝기와 상관없이 배경이어야 한다.
        XCTAssertFalse(image[20, 35])
        XCTAssertFalse(image[width - 20, 35], "그림자를 잉크로 읽었다")
    }

    /// 손으로 든 폰은 반드시 조금 기운다. 기울어지면 한 행에 오선이 통째로 들어오지 않아
    /// 수평 투영의 봉우리가 뭉개지고, 오선 검출이 실패한다.
    func testDeskewMakesTiltedStaffLinesDetectableAgain() {
        let width = 300, height = 160
        var tilted = BinaryImage(width: width, height: height)
        for lineIndex in 0..<5 {
            for x in 10..<(width - 10) {
                // 가로로 갈수록 3.4도쯤 내려가는 오선
                let y = 40 + lineIndex * 12 + Int(Double(x) * 0.06)
                tilted[x, y] = true
                tilted[x, y + 1] = true
            }
        }

        XCTAssertTrue(StaffDetector.detect(in: tilted).isEmpty, "기울어진 채로는 못 찾는 게 정상이다")

        let straightened = SheetMusicImagePreprocessor.deskewed(tilted)

        let staves = StaffDetector.detect(in: straightened)
        XCTAssertEqual(staves.count, 1)
        XCTAssertEqual(staves.first?.spacing ?? 0, 12, accuracy: 1.5)
    }

    /// 이미 반듯한 사진을 괜히 흔들어놓으면 안 된다.
    func testDeskewLeavesStraightImagesAlone() {
        var straight = BinaryImage(width: 200, height: 120)
        for lineIndex in 0..<5 {
            for x in 10..<190 { straight[x, 30 + lineIndex * 12] = true }
        }

        let result = SheetMusicImagePreprocessor.deskewed(straight)

        XCTAssertEqual(StaffDetector.detect(in: result).count, 1)
    }

    /// 큰 사진은 줄여서 다룬다 — 우리가 재는 것 중 가장 작은 게 줄 간격이라 원본 해상도가
    /// 필요 없고, 픽셀 수가 줄면 검출 시간도 그만큼 줄어든다.
    func testDownscalesLargePhotos() throws {
        let context = CGContext(data: nil, width: 3200, height: 2400, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        let cgImage = try XCTUnwrap(context?.makeImage())

        let image = try XCTUnwrap(SheetMusicImagePreprocessor.binarize(cgImage))

        XCTAssertEqual(image.width, SheetMusicImagePreprocessor.workingMaximumDimension)
        XCTAssertEqual(image.height, 1200)
    }
}
