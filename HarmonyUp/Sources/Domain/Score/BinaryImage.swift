import Foundation

/// 이진화된 흑백 비트맵 — `true`가 잉크(검정)다 (156절, 악보 사진 읽기).
///
/// **왜 별도 타입인가**: 악보 사진에서 음을 읽어내는 과정(오선 검출 → 오선 제거 → 음표 머리
/// 검출)은 전부 순수 계산이다. `CGImage` 의존을 전처리 한 곳에 가둬두면 나머지 알고리즘을
/// 오디오 없이 테스트하듯 **이미지 없이** 유닛테스트로 고정할 수 있다(`CLAUDE.md`: 신호처리
/// 함수는 순수 함수로 분리).
struct BinaryImage: Equatable {
    let width: Int
    let height: Int
    private(set) var pixels: [Bool]

    init(width: Int, height: Int, pixels: [Bool]) {
        precondition(pixels.count == width * height, "픽셀 수가 크기와 맞지 않는다")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init(width: Int, height: Int, ink: Bool = false) {
        self.init(width: width, height: height,
                  pixels: [Bool](repeating: ink, count: max(0, width * height)))
    }

    /// 테스트에서 작은 그림을 그대로 적어 만들 때 쓴다 — `#`이 잉크, 나머지는 배경.
    init(rows: [String]) {
        let height = rows.count
        let width = rows.map(\.count).max() ?? 0
        var pixels = [Bool](repeating: false, count: width * height)
        for (y, row) in rows.enumerated() {
            for (x, character) in row.enumerated() {
                pixels[y * width + x] = (character == "#")
            }
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    subscript(x: Int, y: Int) -> Bool {
        get {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return pixels[y * width + x]
        }
        set {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            pixels[y * width + x] = newValue
        }
    }

    /// 행마다 잉크 픽셀이 몇 개인지 — 오선 검출의 출발점(수평 투영 프로파일)이다.
    /// 오선은 이미지를 가로지르는 긴 직선이라 이 값이 뚜렷한 봉우리를 만든다.
    func inkCountPerRow() -> [Int] {
        (0..<height).map { y in
            (0..<width).reduce(0) { count, x in count + (self[x, y] ? 1 : 0) }
        }
    }

    /// 세로로 이어진 잉크의 길이 — `(x, y)`에서 위아래로 몇 픽셀이나 잉크가 붙어 있는지.
    /// 오선을 지울 때 "이건 선인가, 선을 지나가는 음표/줄기인가"를 가르는 데 쓴다.
    func verticalRunLength(x: Int, y: Int) -> Int {
        guard self[x, y] else { return 0 }
        var length = 1
        var above = y - 1
        while above >= 0, self[x, above] { length += 1; above -= 1 }
        var below = y + 1
        while below < height, self[x, below] { length += 1; below += 1 }
        return length
    }
}

// MARK: - 연결 요소 (156절)

extension BinaryImage {

    /// 서로 붙어 있는 잉크 덩어리 하나. 어디에 얼마나 큰 게 있는지만 알면 되는 자리가
    /// 많아서(기호 분류, 크기 거르기) 픽셀 목록 대신 테두리 상자와 개수만 들고 있는다.
    struct Component: Equatable {
        let minX: Int
        let maxX: Int
        let minY: Int
        let maxY: Int
        let pixelCount: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    /// 주어진 범위 안에서 4방향으로 이어진 잉크 덩어리들을 찾는다.
    func inkComponents(xRange: ClosedRange<Int>, yRange: ClosedRange<Int>) -> [Component] {
        let xs = xRange.clamped(to: 0...(max(0, width - 1)))
        let ys = yRange.clamped(to: 0...(max(0, height - 1)))
        // 사진 한 장은 픽셀이 백만 단위라 Set 해싱이 그대로 병목이 된다 — 방문 표시는 배열로.
        var visited = [Bool](repeating: false, count: width * height)
        var components: [Component] = []

        for startY in ys {
            for startX in xs {
                let startIndex = startY * width + startX
                guard self[startX, startY], !visited[startIndex] else { continue }

                var stack = [(startX, startY)]
                visited[startIndex] = true
                var minX = startX, maxX = startX, minY = startY, maxY = startY
                var count = 0

                while let (x, y) = stack.popLast() {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)

                    for (nextX, nextY) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                        guard xs.contains(nextX), ys.contains(nextY), self[nextX, nextY] else { continue }
                        let index = nextY * width + nextX
                        guard !visited[index] else { continue }
                        visited[index] = true
                        stack.append((nextX, nextY))
                    }
                }

                components.append(Component(minX: minX, maxX: maxX, minY: minY, maxY: maxY, pixelCount: count))
            }
        }
        return components
    }
}
