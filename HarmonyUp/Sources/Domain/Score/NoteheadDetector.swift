import Foundation

/// 오선을 지운 뒤 남은 것에서 음표 머리를 찾는다 (156절).
///
/// **왜 머리만 찾는가**: 이 앱은 악보에서 **음높이 순서**만 필요하다 — 리듬은 실제로 부른
/// 그대로 쓰기 때문이다(155절 교정 규칙: 음높이만 고치고 타이밍은 안 고친다). OMR에서 가장
/// 어려운 박자·음가 해석(깃발, 점, 이음줄, 잇단음표…)을 통째로 건너뛸 수 있고, 남는 건
/// "타원이 어디 있나"라는 훨씬 단순한 문제다.
///
/// 세 걸음이다.
/// 1. **오선 지우기** — 세로로 짧게 지나가는 잉크만 지운다. 머리·줄기가 지나가는 자리는 남는다
/// 2. **구멍 메우기** — 빈 머리(2분·온음표)를 채워진 머리와 같은 모양으로 만든다
/// 3. **창 맞춰보기** — 머리 크기의 창을 훑어 잉크가 꽉 찬 자리를 고른다
enum NoteheadDetector {

    struct Notehead: Equatable {
        let x: Double
        let y: Double
    }

    /// 창 안이 이만큼 잉크여야 머리로 본다. 타원이 사각 창을 채우는 비율이 약 0.8이라
    /// 그보다 낮게 잡되, 줄기만 지나가는 자리(0.15 안팎)와는 확실히 갈리는 값이다.
    private static let minimumFillRatio = 0.62

    /// 좌우로 계속 이어지는 잉크는 머리가 아니라 **빔**(8분음표를 잇는 굵은 사선)이다.
    /// 창 바깥 좌우 띠가 차 있으면 그만큼 점수를 깎아 빔을 걸러낸다.
    private static let sideBandPenalty = 0.7

    /// 위아래로도 계속 굵게 이어지는 잉크는 **음자리표**다(실측에서 걸렸다 — VexFlow가 그린
    /// 진짜 악보를 읽히자 높은음자리표의 굵은 곡선이 머리 다섯 개로 잡혔고, 그 헛것이 첫 음표
    /// 자리를 차지하는 바람에 조표 검색 범위까지 잘려 샤프를 놓쳤다).
    ///
    /// **위아래 중 작은 쪽을 본다.** 진짜 머리는 줄기가 한쪽으로만 뻗고 그 줄기도 창 너비에
    /// 비해 얇아서 양쪽 중 하나는 거의 비어 있다. 음자리표는 양쪽 다 차 있다.
    private static let verticalBandPenalty = 0.7

    static func detect(in image: BinaryImage, staff: StaffDetector.Staff) -> [Notehead] {
        // **순서가 중요하다: 구멍부터 메우고 그다음에 오선을 지운다.**
        //
        // 실측에서 뒤집혀 있던 걸 잡았다 — VexFlow가 그린 2분음표(빈 머리)를 하나도 못 찾았다.
        // 오선을 먼저 지우면, 머리 테두리에서 가장 얇은 좌우 끝이 오선과 겹칠 때 함께 지워져
        // 구멍이 바깥으로 새고, 그러면 메울 대상이 아니게 된다. 원본에서는 테두리가 온전해서
        // 오선이 머리를 관통해도 구멍은 조각날 뿐 여전히 닫혀 있다.
        let cleaned = removingStaffLines(from: fillingHoles(in: image, staff: staff), staff: staff)
        let integral = IntegralImage(cleaned)

        let windowWidth = max(3, Int((staff.spacing * 1.25).rounded()))
        let windowHeight = max(3, Int((staff.spacing * 0.95).rounded()))
        let bandWidth = max(2, Int((staff.spacing * 0.55).rounded()))
        let bandHeight = max(2, Int((staff.spacing * 0.5).rounded()))
        let windowArea = Double(windowWidth * windowHeight)

        let yRange = staff.searchRange().clamped(to: 0...(image.height - 1))
        let startX = noteSearchStartX(in: cleaned, staff: staff)
        guard startX <= staff.maxX else { return [] }

        var candidates: [(score: Double, head: Notehead)] = []

        for y in yRange {
            for x in startX...staff.maxX {
                let left = x - windowWidth / 2
                let top = y - windowHeight / 2
                let fill = Double(integral.sum(x: left, y: top, width: windowWidth, height: windowHeight)) / windowArea
                guard fill >= minimumFillRatio else { continue }

                // 창 양옆 띠 — 빔처럼 가로로 이어지는 것이면 여기도 차 있다.
                let bandArea = Double(bandWidth * windowHeight)
                let leftBand = Double(integral.sum(x: left - bandWidth, y: top, width: bandWidth, height: windowHeight)) / bandArea
                let rightBand = Double(integral.sum(x: left + windowWidth, y: top, width: bandWidth, height: windowHeight)) / bandArea

                // 창 위아래 띠 — 음자리표처럼 세로로 계속 굵은 것이면 여기도 차 있다.
                let verticalBandArea = Double(windowWidth * bandHeight)
                let topBand = Double(integral.sum(x: left, y: top - bandHeight, width: windowWidth, height: bandHeight)) / verticalBandArea
                let bottomBand = Double(integral.sum(x: left, y: top + windowHeight, width: windowWidth, height: bandHeight)) / verticalBandArea

                let score = fill
                    - sideBandPenalty * min(leftBand, rightBand)
                    - verticalBandPenalty * min(topBand, bottomBand)
                guard score >= minimumFillRatio else { continue }

                candidates.append((score, Notehead(x: Double(x), y: Double(y))))
            }
        }

        return suppressNeighbors(candidates, minimumDistance: staff.spacing * 0.9)
            .sorted { $0.x < $1.x }
    }

    /// 오선 앞머리의 **음자리표를 통째로 건너뛴다.**
    ///
    /// 실측에서 나온 수정이다 — VexFlow가 그린 진짜 악보를 읽히자 높은음자리표의 굵은 곡선이
    /// 음표 머리로 잡혔고, 그 헛것이 "첫 음표" 자리를 차지하는 바람에 조표 검색 범위까지
    /// 잘려 샤프를 놓쳤다. 창 위아래 띠 감점으로 대부분 사라졌지만 곡선의 일부는 국소적으로
    /// 머리와 구분되지 않는다 — 애초에 그 자리를 안 보는 편이 확실하다.
    ///
    /// 음자리표는 **오선 위아래로 넘치게 크다**는 게 음표와 다른 점이다(줄기까지 합친 음표가
    /// 오선 3~4칸이라면 음자리표는 6칸을 넘는다).
    private static func noteSearchStartX(in image: BinaryImage, staff: StaffDetector.Staff) -> Int {
        let probeEnd = min(staff.maxX, staff.minX + Int(staff.spacing * 5))
        guard staff.minX < probeEnd else { return staff.minX }

        let yRange = staff.searchRange(extraSteps: 8).clamped(to: 0...(image.height - 1))
        let tall = image.inkComponents(xRange: staff.minX...probeEnd, yRange: yRange)
            .filter { Double($0.height) >= staff.spacing * 4.5 }

        guard let clefEnd = tall.map(\.maxX).max() else { return staff.minX }
        return clefEnd + max(1, Int(staff.spacing * 0.3))
    }

    // MARK: - 1. 오선 지우기

    /// 오선 위의 잉크 중 **세로로 짧게 지나가는 것만** 지운다.
    ///
    /// 같은 자리라도 음표 머리나 줄기가 겹쳐 있으면 세로 길이가 훨씬 길다 — 그걸 남기지 않으면
    /// 줄 위에 놓인 음표가 두 조각으로 잘려 검출을 놓친다. 오선을 통째로 행 단위로 지우는
    /// 단순한 방법이 실패하는 지점이 바로 여기다.
    static func removingStaffLines(from image: BinaryImage, staff: StaffDetector.Staff) -> BinaryImage {
        var result = image
        // 선 두께의 넉넉한 상한. 사진에서 선이 번지거나 두 픽셀로 찍히는 걸 감안한다.
        let maximumRunLength = max(2, Int(staff.spacing * 0.45))
        let halfBand = max(1, Int((staff.spacing * 0.2).rounded()))

        for lineY in staff.lineYs {
            let center = Int(lineY.rounded())
            for y in (center - halfBand)...(center + halfBand) {
                guard y >= 0, y < image.height else { continue }
                for x in 0..<image.width where image[x, y] {
                    if image.verticalRunLength(x: x, y: y) <= maximumRunLength {
                        result[x, y] = false
                    }
                }
            }
        }
        return result
    }

    // MARK: - 2. 구멍 메우기

    /// 잉크로 완전히 둘러싸인 배경(= 구멍)을 잉크로 채운다 — 빈 머리(2분·온음표)를 채워진
    /// 머리와 같은 모양으로 만들기 위해서다.
    ///
    /// **크기 제한이 필요하다**: 마디선과 오선이 만드는 큰 빈 칸도 원리상 "둘러싸인 배경"이라,
    /// 제한이 없으면 악보 절반이 잉크가 된다. 머리 하나 넓이의 두 배까지만 채운다.
    private static func fillingHoles(in image: BinaryImage, staff: StaffDetector.Staff) -> BinaryImage {
        var visited = [Bool](repeating: false, count: image.width * image.height)
        var result = image
        let maximumHoleArea = Int(staff.spacing * staff.spacing * 2)

        // 이 오선이 실제로 쓰는 띠만 본다 — 사진 전체를 훑으면 단(system) 개수만큼 반복된다.
        let yRange = staff.searchRange().clamped(to: 0...(image.height - 1))
        let xRange = (staff.minX...staff.maxX).clamped(to: 0...(image.width - 1))

        for startY in yRange {
            for startX in xRange {
                let startIndex = startY * image.width + startX
                guard !visited[startIndex], !image[startX, startY] else { continue }

                // 배경 한 덩어리를 훑으면서 이미지 가장자리에 닿는지 본다 — 닿으면 바깥 배경이다.
                var stack = [(startX, startY)]
                var region: [Int] = []
                var touchesBorder = false
                visited[startIndex] = true

                while let (x, y) = stack.popLast() {
                    region.append(y * image.width + x)
                    // 훑는 띠의 가장자리에 닿으면 "바깥과 이어진 배경"으로 본다 — 잘라낸 경계를
                    // 벽으로 치면 오선 위아래 여백이 통째로 구멍으로 잡힌다.
                    if x == xRange.lowerBound || x == xRange.upperBound
                        || y == yRange.lowerBound || y == yRange.upperBound { touchesBorder = true }

                    for (nextX, nextY) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                        guard xRange.contains(nextX), yRange.contains(nextY) else { continue }
                        let index = nextY * image.width + nextX
                        guard !visited[index], !image[nextX, nextY] else { continue }
                        visited[index] = true
                        stack.append((nextX, nextY))
                    }
                }

                guard !touchesBorder, region.count <= maximumHoleArea else { continue }
                for index in region {
                    result[index % image.width, index / image.width] = true
                }
            }
        }
        return result
    }

    // MARK: - 3. 겹친 후보 정리

    /// 한 머리 주변에서는 여러 위치가 함께 높은 점수를 받는다 — 그중 가장 높은 하나만 남긴다.
    private static func suppressNeighbors(_ candidates: [(score: Double, head: Notehead)],
                                          minimumDistance: Double) -> [Notehead] {
        var accepted: [Notehead] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            let isFarEnough = accepted.allSatisfy { existing in
                let dx = existing.x - candidate.head.x
                let dy = existing.y - candidate.head.y
                return (dx * dx + dy * dy).squareRoot() >= minimumDistance
            }
            if isFarEnough { accepted.append(candidate.head) }
        }
        return accepted
    }
}

/// 직사각형 영역의 잉크 개수를 상수 시간에 세기 위한 누적합(적분 영상).
///
/// 창을 픽셀마다 옮겨가며 매번 세면 사진 한 장에 수억 번 접근하게 된다 — 미리 한 번
/// 누적해두면 어느 크기의 창이든 네 번 조회로 끝난다.
struct IntegralImage {
    private let width: Int
    private let height: Int
    private let sums: [Int]

    init(_ image: BinaryImage) {
        width = image.width
        height = image.height
        var sums = [Int](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0
            for x in 0..<width {
                rowSum += image[x, y] ? 1 : 0
                sums[(y + 1) * (width + 1) + (x + 1)] = sums[y * (width + 1) + (x + 1)] + rowSum
            }
        }
        self.sums = sums
    }

    /// 이미지 밖으로 나간 부분은 배경(잉크 없음)으로 친다.
    func sum(x: Int, y: Int, width windowWidth: Int, height windowHeight: Int) -> Int {
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(width, x + windowWidth)
        let y1 = min(height, y + windowHeight)
        guard x0 < x1, y0 < y1 else { return 0 }

        let stride = width + 1
        return sums[y1 * stride + x1] - sums[y0 * stride + x1] - sums[y1 * stride + x0] + sums[y0 * stride + x0]
    }
}
