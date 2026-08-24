import Foundation

/// 악보 사진에서 오선(5줄)을 찾는다 (156절).
///
/// **오선이 모든 것의 기준자다.** 찾고 나면 두 가지가 한꺼번에 정해진다.
/// - **음높이의 눈금**: 줄과 칸이 번갈아 온음계 한 계단씩이다
/// - **크기 척도**: 음표 머리 크기도, 조표 기호 크기도 전부 줄 간격의 배수다
///
/// 그래서 사진의 해상도나 촬영 거리를 몰라도 뒤 단계가 성립한다 — 절대 픽셀 크기를 쓰는
/// 상수가 하나도 없다는 게 이 파일 이후 코드의 설계 원칙이다.
///
/// **원리**: 오선은 이미지를 가로지르는 긴 직선이라 **행별 잉크 개수**(수평 투영)에 뚜렷한
/// 봉우리를 만든다. 줄기(stem)는 세로로 길지만 가로로는 몇 픽셀뿐이라 봉우리를 못 만들고,
/// 음표 머리도 마찬가지다 — 이 차이가 오선을 가려내는 근거다.
enum StaffDetector {

    struct Staff: Equatable {
        /// 위에서 아래로 5줄의 y좌표. 음높이 계산이 이 순서를 전제한다.
        let lineYs: [Double]
        /// 줄 간격(평균). 온음계로는 **두 계단**에 해당한다(줄 → 칸 → 줄).
        let spacing: Double
        /// 오선의 좌우 끝 — 음표를 찾을 가로 범위를 여기로 좁힌다(페이지 여백에서 헛것을 찾지 않게).
        let minX: Int
        let maxX: Int

        /// 오선 위/아래로 덧줄까지 고려한 세로 탐색 범위. 멜로디는 오선 밖으로도 나간다.
        func searchRange(extraSteps: Int = 6) -> ClosedRange<Int> {
            let margin = spacing * Double(extraSteps) / 2
            return Int((lineYs.first ?? 0) - margin)...Int((lineYs.last ?? 0) + margin)
        }
    }

    /// 행이 "선"으로 인정받으려면 이미지 폭에서 이만큼은 잉크여야 한다.
    ///
    /// 사진이 조금 기울면 한 행이 담는 선의 길이가 줄어들기 때문에 넉넉하게 잡았다.
    /// 대신 아래 간격 균일성 검사가 헛것을 걸러낸다 — 두 관문을 나눠 두는 편이,
    /// 하나를 빡빡하게 조여 진짜 오선을 놓치는 것보다 낫다.
    private static let minimumLineWidthRatio = 0.3

    /// 다섯 줄의 간격이 서로 이만큼 안에서 비슷해야 오선으로 본다.
    ///
    /// 인쇄 악보의 오선 간격은 균일하지만 사진의 원근·기울기로 조금씩 달라진다. 반대로
    /// 표 테두리나 문단 밑줄은 간격이 제각각이라 이 검사에서 걸린다 — **오선이 아닌 걸
    /// 오선으로 읽으면 그 뒤 전부가 헛것이 되므로** 여기서 막는 게 중요하다.
    private static let spacingTolerance = 0.35

    static func detect(in image: BinaryImage) -> [Staff] {
        let lines = horizontalLines(in: image)
        guard lines.count >= 5 else { return [] }

        var staves: [Staff] = []
        var index = 0
        while index + 4 < lines.count {
            let candidate = Array(lines[index...(index + 4)])
            guard let spacing = uniformSpacing(of: candidate.map(\.centerY)) else {
                index += 1
                continue
            }

            let extent = horizontalExtent(of: candidate, in: image)
            staves.append(Staff(
                lineYs: candidate.map(\.centerY),
                spacing: spacing,
                minX: extent.lowerBound,
                maxX: extent.upperBound
            ))
            index += 5   // 이 다섯 줄은 소비했다 — 다음 단(system)부터 다시 본다
        }
        return staves
    }

    // MARK: - 내부

    private struct Line {
        let centerY: Double
        let topY: Int
        let bottomY: Int
    }

    /// 수평 투영에서 봉우리를 이루는 행들을 묶어 "선" 하나로 만든다.
    /// 선은 두께가 있으므로(인쇄물도 사진도 1픽셀이 아니다) 연속된 행을 하나로 합친다.
    private static func horizontalLines(in image: BinaryImage) -> [Line] {
        let rowInk = image.inkCountPerRow()
        guard let maxInk = rowInk.max(), maxInk > 0 else { return [] }

        let threshold = max(Double(image.width) * minimumLineWidthRatio, Double(maxInk) * 0.5)

        var lines: [Line] = []
        var runStart: Int?
        for y in 0..<image.height {
            let isLine = Double(rowInk[y]) >= threshold
            if isLine, runStart == nil {
                runStart = y
            } else if !isLine, let start = runStart {
                lines.append(Line(centerY: Double(start + y - 1) / 2, topY: start, bottomY: y - 1))
                runStart = nil
            }
        }
        if let start = runStart {
            lines.append(Line(centerY: Double(start + image.height - 1) / 2,
                              topY: start, bottomY: image.height - 1))
        }
        return lines
    }

    /// 다섯 줄의 간격이 충분히 균일하면 평균 간격을, 아니면 nil을 준다.
    private static func uniformSpacing(of centers: [Double]) -> Double? {
        let gaps = zip(centers.dropFirst(), centers).map(-)
        guard gaps.count == 4, gaps.allSatisfy({ $0 > 0 }) else { return nil }

        let average = gaps.reduce(0, +) / Double(gaps.count)
        guard average > 0 else { return nil }
        let isUniform = gaps.allSatisfy { abs($0 - average) / average <= spacingTolerance }
        return isUniform ? average : nil
    }

    /// 다섯 줄이 실제로 잉크를 갖는 x 범위의 합집합 — 오선의 좌우 끝이다.
    private static func horizontalExtent(of lines: [Line], in image: BinaryImage) -> ClosedRange<Int> {
        var minX = image.width - 1
        var maxX = 0
        for line in lines {
            for y in line.topY...line.bottomY {
                for x in 0..<image.width where image[x, y] {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        guard minX <= maxX else { return 0...(image.width - 1) }
        return minX...maxX
    }
}
