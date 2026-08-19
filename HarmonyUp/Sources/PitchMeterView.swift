import SwiftUI

/// 기타 튜너 앱처럼, 목표음 대비 얼마나 낮게/높게 부르고 있는지를 가로 미터 위 바늘로 보여준다.
/// 텍스트로 "몇 cent 벗어남"이라고만 보여주는 것보다, 좌우로 움직이는 바늘이
/// "지금 낮은지/높은지/거의 다 왔는지"를 훨씬 직관적으로 전달한다.
struct PitchMeterView: View {
    let centsOffset: Double?
    let isOnPitch: Bool
    let toleranceCents: Double
    /// 명세서(v1.0) "실시간 피치 피드백(Glow & Haptic)" — 허용오차 진입 시 바늘/눈금이 이
    /// 성부 고유 색(`Theme.intervalColor`)으로 빛난다. 채점 상태색(pitchGood)과는 별개로,
    /// "지금 몇 도 성부를 맞혔는지"까지 색으로 같이 전달한다.
    let intervalColor: Color

    // 미터가 표현하는 편차 범위. 이보다 크게 벗어나면 끝에 붙여서(clamp) 보여준다 —
    // 반음(100 cent)까지 다 보여주면 바늘이 조금만 벗어나도 안 움직이는 것처럼 보여서,
    // 실제 채점 허용범위(±35 cent)보다 살짝 넓은 ±50 cent를 화면 전체 폭으로 잡았다.
    private let displayRangeCents: Double = 50

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let midX = w / 2
                let toleranceWidth = w * CGFloat(min(toleranceCents, displayRangeCents) / displayRangeCents)

                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.15))

                    // 허용오차(정확 판정) 구간을 중앙에 음영으로 표시 — 실제로 그 안에 들어와
                    // 있으면(isOnPitch) 성부색으로 밝게 빛나는(Glow) 상태로 전환한다.
                    RoundedRectangle(cornerRadius: 5)
                        .fill((isOnPitch ? intervalColor : Theme.pitchGood).opacity(isOnPitch ? 0.35 : 0.22))
                        .frame(width: toleranceWidth)
                        .position(x: midX, y: h / 2)
                        .shadow(color: isOnPitch ? intervalColor.opacity(0.85) : .clear, radius: isOnPitch ? 10 : 0)
                        .animation(.easeOut(duration: 0.15), value: isOnPitch)

                    // 0 cent(정확히 목표음) 기준선
                    Rectangle()
                        .fill(Color.secondary.opacity(0.7))
                        .frame(width: 2)
                        .position(x: midX, y: h / 2)

                    if let cents = centsOffset {
                        let clamped = max(-displayRangeCents, min(displayRangeCents, cents))
                        let x = midX + CGFloat(clamped / displayRangeCents) * (w / 2)

                        Circle()
                            .fill(isOnPitch ? intervalColor : Theme.pitchBad)
                            .frame(width: 20, height: 20)
                            .shadow(color: isOnPitch ? intervalColor.opacity(0.9) : .clear, radius: isOnPitch ? 8 : 0)
                            .position(x: x, y: h / 2)
                            .animation(.easeOut(duration: 0.12), value: cents)
                            .animation(.easeOut(duration: 0.15), value: isOnPitch)
                    }
                }
            }
            .frame(height: 32)

            HStack {
                Text("♭ 낮음")
                Spacer()
                Text("정확")
                Spacer()
                Text("♯ 높음")
            }
            .font(Theme.Typography.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
