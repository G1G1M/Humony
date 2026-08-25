import CoreGraphics
import Foundation

/// 사진을 악보 읽기가 다룰 수 있는 흑백 비트맵으로 바꾼다 (156절).
///
/// **`CGImage` 의존을 여기 한 곳에 가둔다.** 이 뒤의 모든 단계(오선 검출, 음표 머리, 조표)는
/// `BinaryImage`만 받는 순수 함수라 이미지 파일 없이 유닛테스트로 고정된다.
///
/// 두 가지가 사진을 스캔본과 다르게 만든다 — **고르지 않은 조명**과 **기울어짐**. 둘 다
/// 여기서 처리한다.
enum SheetMusicImagePreprocessor {

    /// 긴 변을 이 크기로 줄여서 다룬다.
    ///
    /// 요즘 폰 사진은 4000픽셀이 넘는데, 우리가 재는 것 중 가장 작은 게 오선 줄 간격(보통
    /// 사진 폭의 1/40 이상)이라 그만한 해상도가 필요 없다. 픽셀 수가 4배 줄면 검출 시간도
    /// 그만큼 줄어든다.
    static let workingMaximumDimension = 1600

    /// 지역 평균보다 이 비율만큼 어두우면 잉크로 본다.
    ///
    /// **전역 임계값(예: Otsu)이 사진에서 실패하는 이유**: 한쪽에 그림자가 지면 그 영역이
    /// 통째로 잉크가 되거나 통째로 배경이 된다. 주변 평균과 비교하면 밝기가 달라도 "주변보다
    /// 어두운 선"은 똑같이 잡힌다.
    private static let localThresholdRatio = 0.88

    /// 기울기를 이 범위에서 찾는다. 손으로 든 폰이 흔히 만드는 정도다 — 그보다 크게 기울여
    /// 찍었으면 다시 찍는 게 낫고, 범위를 넓히면 엉뚱한 각도에 걸릴 위험만 커진다.
    private static let maximumSkewDegrees = 6.0

    // MARK: - 사진 → 흑백

    static func binarize(_ cgImage: CGImage,
                         maximumDimension: Int = workingMaximumDimension) -> BinaryImage? {
        guard let gray = grayscalePixels(cgImage, maximumDimension: maximumDimension) else { return nil }
        return binarize(gray: gray.pixels, width: gray.width, height: gray.height)
    }

    /// 지역 평균 기반 적응 이진화. 창 평균은 누적합으로 상수 시간에 구한다.
    static func binarize(gray: [UInt8], width: Int, height: Int) -> BinaryImage {
        guard width > 0, height > 0 else { return BinaryImage(width: 0, height: 0) }

        // 창 크기는 "오선 몇 줄이 들어갈 만큼"이면 된다 — 너무 작으면 굵은 획 안쪽이 배경이 되고,
        // 너무 크면 전역 임계값과 다를 바 없어진다.
        let window = max(15, width / 24)
        let stride = width + 1
        var sums = [Int](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var rowSum = 0
            for x in 0..<width {
                rowSum += Int(gray[y * width + x])
                sums[(y + 1) * stride + (x + 1)] = sums[y * stride + (x + 1)] + rowSum
            }
        }

        var pixels = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            let y0 = max(0, y - window / 2)
            let y1 = min(height, y + window / 2 + 1)
            for x in 0..<width {
                let x0 = max(0, x - window / 2)
                let x1 = min(width, x + window / 2 + 1)
                let area = (x1 - x0) * (y1 - y0)
                guard area > 0 else { continue }

                let total = sums[y1 * stride + x1] - sums[y0 * stride + x1]
                    - sums[y1 * stride + x0] + sums[y0 * stride + x0]
                let mean = Double(total) / Double(area)
                pixels[y * width + x] = Double(gray[y * width + x]) < mean * localThresholdRatio
            }
        }
        return BinaryImage(width: width, height: height, pixels: pixels)
    }

    // MARK: - 기울기 보정

    /// 오선이 수평이 되도록 세로로 밀어(shear) 편다.
    ///
    /// **왜 회전이 아니라 shear인가**: 몇 도 안 되는 각도에서 둘의 차이는 오선 검출에 영향을
    /// 주지 않는데, shear는 곱셈 하나로 끝나고 보간도 필요 없다.
    ///
    /// **어느 각도가 맞는지 어떻게 아는가**: 오선이 수평일 때 행별 잉크 개수가 가장 뾰족해진다
    /// (한 행에 선 하나가 통째로 들어간다). 그 뾰족함을 제곱합으로 재서 가장 큰 각도를 고른다 —
    /// 문서 기울기 보정의 고전적인 방법이다.
    static func deskewed(_ image: BinaryImage) -> BinaryImage {
        guard image.width > 1, image.height > 1 else { return image }

        var bestShift = 0.0
        var bestScore = -1.0
        var degrees = -maximumSkewDegrees
        while degrees <= maximumSkewDegrees {
            let shift = tan(degrees * Double.pi / 180)
            let score = projectionSharpness(of: image, shiftPerPixel: shift)
            if score > bestScore {
                bestScore = score
                bestShift = shift
            }
            degrees += 0.5
        }

        guard abs(bestShift) > 1e-6 else { return image }

        var result = BinaryImage(width: image.width, height: image.height)
        for x in 0..<image.width {
            let offset = Int((Double(x) * bestShift).rounded())
            for y in 0..<image.height where image[x, y] {
                result[x, y - offset] = true
            }
        }
        return result
    }

    private static func projectionSharpness(of image: BinaryImage, shiftPerPixel: Double) -> Double {
        var rowCounts = [Int](repeating: 0, count: image.height)
        for x in 0..<image.width {
            let offset = Int((Double(x) * shiftPerPixel).rounded())
            for y in 0..<image.height where image[x, y] {
                let corrected = y - offset
                guard corrected >= 0, corrected < image.height else { continue }
                rowCounts[corrected] += 1
            }
        }
        // 제곱합 — 같은 잉크 양이라도 몇 행에 몰려 있을수록 커진다.
        return rowCounts.reduce(0.0) { $0 + Double($1) * Double($1) }
    }

    // MARK: - 내부

    private static func grayscalePixels(_ cgImage: CGImage,
                                        maximumDimension: Int) -> (pixels: [UInt8], width: Int, height: Int)? {
        let longest = max(cgImage.width, cgImage.height)
        let scale = longest > maximumDimension ? Double(maximumDimension) / Double(longest) : 1.0
        let width = max(1, Int(Double(cgImage.width) * scale))
        let height = max(1, Int(Double(cgImage.height) * scale))

        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = pixels.withUnsafeMutableBytes({ buffer -> CGContext? in
            guard let base = buffer.baseAddress else { return nil }
            return CGContext(data: base, width: width, height: height,
                             bitsPerComponent: 8, bytesPerRow: width,
                             space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }) else { return nil }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (pixels, width, height)
    }
}
