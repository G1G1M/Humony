import Foundation

/// 오선 앞머리의 조표(샤프·플랫 개수)를 읽는다 (156절).
///
/// **왜 꼭 읽어야 하는가**: G장조 악보에서 F 자리 음표는 F가 아니라 F#이다. 이건 조옮김
/// 추정으로 못 고친다 — 전체가 밀린 게 아니라 특정 음이름만 반음 다르기 때문이다. 조표를
/// 놓치면 그 악보로 교정한 결과가 오히려 채보를 망친다.
///
/// **샤프와 플랫을 가르는 단서는 위쪽 절반이다.** 샤프는 위쪽에도 가로줄이 지나가 넓게
/// 퍼져 있고, 플랫은 위로 뻗은 얇은 줄기 하나뿐이다(배는 아래쪽에 있다). 기호를 통째로
/// 알아보려 하지 않고 이 한 가지 성질만 재는 편이 사진 품질에 훨씬 덜 휘둘린다.
enum KeySignatureReader {

    /// 조표에 쓸 수 있는 최대 개수 — 그보다 많이 세었으면 뭔가를 잘못 읽은 것이다.
    private static let maximumAccidentals = 7

    /// 조각을 같은 기호로 되묶는 가로 간격의 상한(줄 간격 대비).
    ///
    /// **양쪽에서 조여오는 값이다.** 크게 잡으면 이웃한 조표 기호끼리 붙어 하나로 세어지고,
    /// 작게 잡으면 오선을 지우다 가로줄이 끊긴 샤프가 세로줄 두 개로 흩어져 아예 안 세어진다.
    /// 샤프 안쪽 두 세로줄 간격(약 0.4)과 조표 기호 사이 여백(약 0.5 이상) 사이를 잡았다.
    private static let fragmentMergeGapRatio = 0.45

    /// 위쪽 절반의 가로 퍼짐이 줄 간격의 이 비율을 넘으면 샤프로 본다.
    ///
    /// 샤프는 세로줄 둘만으로도 0.5를 넘고 플랫은 줄기 하나라 0.2를 밑돈다 — 둘 사이가
    /// 넓게 벌어져 있어서, 사진이 흐리거나 오선을 지우며 가로줄이 조금 깎여도 안전하다.
    private static let sharpUpperWidthRatio = 0.35

    /// - Parameter beforeX: 첫 음표 머리의 x. 그 뒤에 나오는 샤프·플랫은 **조표가 아니라
    ///   곡 중간의 임시표**이므로 여기서 검색을 끊는다.
    /// - Returns: 5도권 개수(샤프 양수, 플랫 음수). 조표가 없으면 0.
    ///   **잘못 읽었다고 판단되면 nil** — 155절 계약대로 모르는 걸 0으로 지어내면 뒤 단계가
    ///   "악보에서 온 확실한 값"으로 믿어버린다.
    static func fifths(in image: BinaryImage, staff: StaffDetector.Staff, beforeX: Double) -> Int? {
        let searchEndX = min(staff.maxX, Int(beforeX) - 1)
        guard staff.minX < searchEndX else { return 0 }

        let withoutStaffLines = NoteheadDetector.removingStaffLines(from: image, staff: staff)
        let yRange = staff.searchRange(extraSteps: 4).clamped(to: 0...(image.height - 1))

        // 오선을 지우면 기호가 조각날 수 있다(가로줄이 선과 겹쳐 함께 지워지는 경우) —
        // 가로로 가까운 조각은 같은 기호로 되묶는다.
        let symbols = merged(withoutStaffLines.inkComponents(xRange: staff.minX...searchEndX, yRange: yRange),
                             within: staff.spacing * fragmentMergeGapRatio)
            .filter { isAccidentalSized($0, spacing: staff.spacing) }
            .sorted { $0.minX < $1.minX }

        guard !symbols.isEmpty else { return 0 }
        guard symbols.count <= maximumAccidentals else { return nil }

        let sharpCount = symbols.filter { isSharp($0, in: withoutStaffLines, spacing: staff.spacing) }.count
        // 실제 조표는 한 종류만 쓴다 — 섞여 나왔다면 잘못 읽은 것이다.
        guard sharpCount == 0 || sharpCount == symbols.count else { return nil }

        return sharpCount > 0 ? symbols.count : -symbols.count
    }

    // MARK: - 내부

    /// 조표 기호는 오선 두세 칸 높이에 폭이 좁다. 음자리표(오선 전체보다 크다)와 박자표
    /// (숫자 하나가 한 칸 남짓)는 이 조건에서 걸러진다.
    private static func isAccidentalSized(_ component: BinaryImage.Component, spacing: Double) -> Bool {
        let height = Double(component.height)
        let width = Double(component.width)
        return height >= spacing * 1.4 && height <= spacing * 3.2
            && width >= spacing * 0.25 && width <= spacing * 1.3
    }

    /// 기호 위쪽 절반에서 잉크가 가로로 얼마나 퍼져 있는지로 샤프·플랫을 가른다.
    private static func isSharp(_ component: BinaryImage.Component,
                                in image: BinaryImage, spacing: Double) -> Bool {
        let upperBottom = component.minY + Int(Double(component.height) * 0.45)
        var minX = component.maxX
        var maxX = component.minX
        var hasInk = false

        for y in component.minY...max(component.minY, upperBottom) {
            for x in component.minX...component.maxX where image[x, y] {
                minX = min(minX, x)
                maxX = max(maxX, x)
                hasInk = true
            }
        }

        guard hasInk else { return false }
        return Double(maxX - minX + 1) / spacing >= sharpUpperWidthRatio
    }

    /// 가로로 가까운(또는 겹치는) 조각들을 하나의 기호로 묶는다.
    private static func merged(_ components: [BinaryImage.Component], within gap: Double) -> [BinaryImage.Component] {
        let sorted = components.sorted { $0.minX < $1.minX }
        var result: [BinaryImage.Component] = []

        for component in sorted {
            guard let last = result.last,
                  Double(component.minX - last.maxX) <= gap else {
                result.append(component)
                continue
            }
            result[result.count - 1] = BinaryImage.Component(
                minX: min(last.minX, component.minX),
                maxX: max(last.maxX, component.maxX),
                minY: min(last.minY, component.minY),
                maxY: max(last.maxY, component.maxY),
                pixelCount: last.pixelCount + component.pixelCount
            )
        }
        return result
    }
}
