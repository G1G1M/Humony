import SwiftUI

/// 녹음 종료~악보 렌더링 사이의 로딩 표시들이 전부 기본 `ProgressView`(정적인 스피너/막대)뿐이라
/// "지금 진행되고 있다"는 느낌이 약하다는 피드백으로 추가한 두 컴포넌트. `QuickRecordView`
/// (수치형 진행률 바)와 `PracticeView`/`SheetMusicFullScreenView`(스피너형, 정확한 진행률을
/// 모르는 단계)가 서로 다른 스타일을 쓴다 — 사용자가 두 스타일을 직접 골랐다: 수치형은 채워진
/// 부분 위로 빛이 스윽 지나가는 shimmer, 스피너형은 전체가 숨쉬듯 커졌다 작아지는 breathing pulse.
///
/// **1차 구현 반려 후 재작업**: 처음 버전은 "하나도 반영 안 된 것 같다, 너무 딱딱하다"는
/// 피드백을 받았다 — 원인 둘 다 실제 버그였다. (1) shimmer의 반짝임 띠가 막대 "전체 너비"
/// 기준 좌표로 움직이는데 실제로 보이는 건 진행률만큼만 채워진(클리핑된) 부분뿐이라, 진행률이
/// 낮을 때는 반짝임이 대부분의 애니메이션 주기 동안 보이지 않는 영역에 가 있었다 — 채워진
/// 너비(fillWidth) 기준 좌표로 바꿔서 항상 보이는 영역 안에서 스윽 지나가게 했다. (2) pulse의
/// 진폭(스케일 0.96~1.04, 불투명도 0.55~1.0)과 주기(1.1초)가 너무 작고 느려서, 로딩 자체가
/// 짧게(수백ms) 끝나는 경우 한 주기도 다 못 보고 사라져 "안 움직인 것처럼" 느껴졌다 — 진폭을
/// 키우고 주기를 절반 이하로 줄여서 짧은 로딩에서도 최소 한 번은 확실히 체감되게 했다.
enum LoadingIndicators {}

/// 진행률(0~1)이 있는 곳 전용 — `ProgressView(value:)`를 그대로 대체한다. 채워진 부분 위에
/// 반투명한 흰색 그라데이션 띠를 좌→우로 반복 이동시켜 반짝임을 낸다.
struct ShimmerProgressBar: View {
    let progress: Double
    /// shimmer 애니메이션이 큰 움직임이라 Reduce Motion에서는 끈다 — 카드 등장 트랜지션 등
    /// 앱 전역에서 이미 존중하는 설정과 같은 원칙(`PracticeView.cardAppearTransition` 참고).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // -0.6~1.6 범위로 움직인다 — 아래 fillWidth * shimmerOffset이 실제 좌표가 되는데, 띠
    // 자체의 폭(fillWidth*0.7)이 있어서 이 범위여야 띠가 채워진 영역 밖에서 시작해 완전히
    // 가로지른 뒤 다시 밖으로 나간다(안 그러면 등장/퇴장이 뚝뚝 끊겨 보인다).
    @State private var shimmerOffset: CGFloat = -0.6

    private let barHeight: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clampedProgress = min(max(progress, 0), 1)
            let fillWidth = max(width * CGFloat(clampedProgress), 0.0001)
            let bandWidth = fillWidth * 0.7

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.tint.opacity(0.15))

                Capsule()
                    .fill(Theme.tint)
                    .frame(width: fillWidth)
                    .overlay(alignment: .leading) {
                        if !reduceMotion {
                            LinearGradient(
                                colors: [.clear, .white.opacity(0.7), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: bandWidth)
                            // 채워진 너비(fillWidth) 기준으로 움직여야 진행률과 무관하게 항상
                            // "지금 보이는 채워진 부분" 안을 스윽 지나가는 것처럼 보인다.
                            .offset(x: shimmerOffset * fillWidth)
                        }
                    }
                    .clipShape(Capsule())
            }
            .animation(.easeInOut(duration: 0.3), value: clampedProgress)
        }
        .frame(height: barHeight)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.6
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
        // 켜짐" 쪽 값으로 떨어지지 않도록 reduceMotion일 땐 항상 정상 크기/불투명도로 고정한다 —
        // 안 그러면 Reduce Motion 사용자에게는 그냥 계속 흐릿하게만 보인다.
        .scaleEffect(reduceMotion ? 1.0 : (isPulsing ? 1.1 : 0.92))
        .opacity(reduceMotion ? 1.0 : (isPulsing ? 1.0 : 0.4))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
