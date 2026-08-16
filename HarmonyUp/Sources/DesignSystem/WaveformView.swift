import SwiftUI

/// 최근 오디오 샘플([Float])을 세로 막대 파형으로 그린다 — "녹음 중"이라는 걸 숫자/텍스트가
/// 아니라 눈으로 바로 느끼게 해주는 목적. 마이크로 들어오는 원본 샘플은 초당 수만 개라
/// 화면에 다 그릴 수 없어서, 보여줄 막대 개수만큼 구간별 최대 진폭(peak)으로 다운샘플링한다.
struct WaveformView: View {
    let samples: [Float]
    var barCount: Int = 40
    var color: Color = Theme.tint

    var body: some View {
        GeometryReader { geo in
            let bars = normalizedPeaks(samples, barCount: barCount)
            HStack(alignment: .center, spacing: geo.size.width / CGFloat(barCount) * 0.35) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, amplitude in
                    Capsule()
                        .fill(color)
                        // 최소 높이를 남겨서, 무음이어도 "막대가 아예 사라진" 게 아니라
                        // "지금은 조용하다"로 보이게 한다.
                        .frame(height: max(4, CGFloat(amplitude) * geo.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 값이 갱신될 때마다(마이크 프레임마다) 막대 높이가 툭툭 끊기지 않고 자연스럽게
            // 따라가도록 짧은 애니메이션을 건다.
            .animation(.easeOut(duration: 0.08), value: bars)
        }
    }

    /// 구간별 최대 진폭을 구한 뒤, 이번 화면에 보이는 막대들 중 가장 큰 값을 기준으로
    /// 다시 정규화한다 — 마이크 원본은 피크가 낮게(0.1~0.3) 들어올 때가 많아서, 매번 절대값
    /// 그대로 그리면 파형이 화면 아래쪽에 작게만 움직여 "녹음되고 있다"는 게 잘 안 느껴진다.
    private func normalizedPeaks(_ samples: [Float], barCount: Int) -> [Float] {
        guard barCount > 0 else { return [] }
        guard !samples.isEmpty else { return Array(repeating: 0, count: barCount) }

        let chunkSize = max(1, samples.count / barCount)
        var peaks: [Float] = []
        peaks.reserveCapacity(barCount)
        var index = 0
        while index < samples.count && peaks.count < barCount {
            let end = min(index + chunkSize, samples.count)
            peaks.append(samples[index..<end].reduce(into: Float(0)) { $0 = max($0, abs($1)) })
            index = end
        }
        while peaks.count < barCount { peaks.append(0) }

        guard let maxPeak = peaks.max(), maxPeak > 0.005 else {
            return Array(repeating: 0, count: barCount)
        }
        return peaks.map { min(1, $0 / maxPeak) }
    }
}
