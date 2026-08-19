import SwiftUI

/// 녹음 종료~악보 렌더링 사이의 로딩 표시들이 전부 기본 `ProgressView`(정적인 스피너/막대)뿐이라
/// "지금 진행되고 있다"는 느낌이 약하다는 피드백으로 추가한 두 컴포넌트. `QuickRecordView`
/// (수치형 진행률 바)와 `PracticeView`/`SheetMusicFullScreenView`(스피너형, 정확한 진행률을
/// 모르는 단계)가 서로 다른 스타일을 쓴다 — 사용자가 두 스타일을 직접 골랐다: 수치형은 채워진
/// 부분 위로 빛이 스윽 지나가는 shimmer, 스피너형은 전체가 숨쉬듯 커졌다 작아지는 breathing pulse.
enum LoadingIndicators {}

/// 진행률(0~1)이 있는 곳 전용 — `ProgressView(value:)`를 그대로 대체한다. 채워진 부분 위에
/// 반투명한 흰색 그라데이션 띠를 좌→우로 반복 이동시켜 반짝임을 낸다.
struct ShimmerProgressBar: View {
    let progress: Double
    /// shimmer 애니메이션이 큰 움직임이라 Reduce Motion에서는 끈다 — 카드 등장 트랜지션 등
    /// 앱 전역에서 이미 존중하는 설정과 같은 원칙(`PracticeView.cardAppearTransition` 참고).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmerOffset: CGFloat = -1

    private let barHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clampedProgress = min(max(progress, 0), 1)
            let fillWidth = width * CGFloat(clampedProgress)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.tint.opacity(0.15))

                Capsule()
                    .fill(Theme.tint)
                    .frame(width: fillWidth)
                    .overlay(alignment: .leading) {
                        if !reduceMotion {
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.55), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: max(width * 0.5, 1))
                            .offset(x: shimmerOffset * width)
                        }
                    }
                    .clipShape(Capsule())
            }
            .animation(.easeInOut(duration: 0.3), value: clampedProgress)
        }
        .frame(height: barHeight)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.5
            }
        }
    }
}

/// 진행률을 모르는(또는 안 보여주는) 로딩 상태 전용 — 기존 `VStack { ProgressView(); Text(...) }`
/// 조합을 그대로 대체한다. 아이콘+텍스트 전체가 숨쉬듯(scale+opacity) 반복 펄스한다.
struct PulsingLoadingLabel: View {
    let message: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ProgressView()
            Text(message)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        // Reduce Motion이 켜져 있으면 애초에 isPulsing을 true로 안 만드니, 여기서도 "펄스 안
        // 켜짐" 쪽 값(0.96/0.55)으로 떨어지지 않도록 reduceMotion일 땐 항상 정상 크기/불투명도로
        // 고정한다 — 안 그러면 Reduce Motion 사용자에게는 그냥 계속 살짝 흐릿하게만 보인다.
        .scaleEffect(reduceMotion ? 1.0 : (isPulsing ? 1.04 : 0.96))
        .opacity(reduceMotion ? 1.0 : (isPulsing ? 1.0 : 0.55))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
