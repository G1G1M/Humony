import Foundation

/// 목표 음 시퀀스와 부른 음 시퀀스를 **순서를 지키면서** 짝짓는다 — 전역 정렬
/// (Needleman-Wunsch와 같은 편집거리 DP). 136절 채점기 안에 있던 것을 155절에 꺼냈다.
///
/// **왜 공유하는가**: 채점("이 음을 얼마나 벗어나게 불렀나")과 악보 교정("이 음이 악보의 어느
/// 음인가")이 정확히 같은 계산을 필요로 한다. 두 벌로 두면 한쪽만 고쳐져 어긋난다.
///
/// **왜 DTW가 아니라 편집거리 정렬인가**: DTW는 한 목표음에 여러 부른 음이(또는 그 반대로)
/// 붙는 many-to-many 대응을 허용해서 "이 음을 빠뜨렸다 / 군더더기로 하나 더 불렀다"를 셀 수가
/// 없다. 편집거리 정렬은 목표음 하나가 정확히 부른 음 하나 또는 공백에만 대응하므로 누락/추가가
/// 결과에 그대로 드러난다 — 사용자에게 보여줄 것이 바로 그것이다.
///
/// **순서대로 1:1(zip)로는 안 되는 이유**: 중간에서 음 하나를 빠뜨리면 그 뒤가 전부 한 칸씩
/// 밀려서 잘 부른 나머지가 모두 오답이 된다.
enum MelodyAligner {

    /// 정렬 결과 한 자리. 둘 다 있으면 짝지어진 것, `sungIndex`가 nil이면 누락(안 부른 목표음),
    /// `targetIndex`가 nil이면 추가(목표에 없는데 부른 음)다.
    struct Pair: Equatable {
        let targetIndex: Int?
        let sungIndex: Int?
    }

    /// - Parameters:
    ///   - targets: 목표 음을 **선형 거리 공간의 좌표**로(cent 권장 — 반음 = 100).
    ///     주파수를 그대로 넣으면 안 된다: 높은 음의 Hz 간격이 낮은 음보다 커서 비용이 왜곡된다.
    ///   - sung: 부른 음을 같은 좌표계로.
    ///   - gapPenalty: 짝을 짓지 않고 건너뛸 때의 비용. 두 음의 거리가 `gapPenalty × 2`보다
    ///     멀면 짝짓는 것보다 각각 건너뛰는 편이 싸진다 — 이 값이 "얼마나 멀면 다른 음으로
    ///     볼 것인가"의 경계다.
    static func align(targets: [Double], sung: [Double], gapPenalty: Double) -> [Pair] {
        let n = targets.count
        let m = sung.count
        guard n > 0 || m > 0 else { return [] }

        // cost[i][j] = 목표 앞 i개와 부른 음 앞 j개를 처리하는 최소 비용
        var cost = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 {
            for i in 1...n { cost[i][0] = Double(i) * gapPenalty }
        }
        if m > 0 {
            for j in 1...m { cost[0][j] = Double(j) * gapPenalty }
        }

        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let match = cost[i - 1][j - 1] + abs(sung[j - 1] - targets[i - 1])
                    let skipTarget = cost[i - 1][j] + gapPenalty // 이 목표음을 안 불렀다
                    let skipSung = cost[i][j - 1] + gapPenalty   // 목표에 없는 음을 불렀다
                    cost[i][j] = min(match, min(skipTarget, skipSung))
                }
            }
        }

        // 되짚어가며 실제 짝을 복원한다. 비용이 같을 때는 짝짓기(match)를 먼저 택한다 —
        // 같은 비용이면 "부른 음이 있었다"는 정보를 살리는 쪽이 사용자에게 더 유용하다.
        var pairs: [Pair] = []
        var i = n
        var j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + abs(sung[j - 1] - targets[i - 1]) {
                pairs.append(Pair(targetIndex: i - 1, sungIndex: j - 1))
                i -= 1
                j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + gapPenalty {
                pairs.append(Pair(targetIndex: i - 1, sungIndex: nil))
                i -= 1
            } else {
                pairs.append(Pair(targetIndex: nil, sungIndex: j - 1))
                j -= 1
            }
        }
        return pairs.reversed()
    }
}
