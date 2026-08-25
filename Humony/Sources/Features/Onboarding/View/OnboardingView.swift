import AVFAudio
import SwiftUI

/// 앱을 처음 켰을 때 한 번 지나가는 3장(`OnboardingPage`).
///
/// **이 화면이 실제로 고치는 문제는 마지막 장 하나다.** 이 앱은 지금까지 마이크 권한을
/// 아무 맥락 없이 물었다 — 녹음 버튼을 누른 순간 시스템 팝업이 예고 없이 떴다. 거부했을 때의
/// 복구 안내(`micPermissionDeniedContent`)는 이미 있었지만, 애초에 왜 필요한지 말해주지 않고
/// 묻는 것과 말하고 묻는 것은 수락률도 납득도 다르다. 앞의 두 장은 그 물음이 뜬금없지 않도록
/// 맥락을 깔아 주는 역할이다.
///
/// 문구는 전부 `OnboardingPage`(순수 타입)에 있다 — 뷰 안의 문자열 리터럴은 테스트가 읽을 수
/// 없어서, "이론 용어 금지" 계약을 테스트로 지킬 수 없게 된다.
///
/// **표면은 전부 리퀴드 글래스로 통일한다.** 심볼 판, 3단계 카드, 단서, 페이지 인디케이터,
/// 버튼 둘까지 같은 재질 체계(`Theme`의 glass 헬퍼)를 쓰고, 한 화면의 글래스 조각들은
/// `Theme.glassGroup`(iOS 26의 `GlassEffectContainer`)으로 묶어 서로의 굴절에 반응하게 한다 —
/// 조각마다 따로 두면 같은 재질인데도 미묘하게 다른 표면처럼 보인다.
struct OnboardingView: View {
    /// 3장을 다 지났거나 건너뛰었을 때. 어느 쪽이든 완료로 친다(`OnboardingGate.markCompleted`).
    let onFinish: () -> Void

    @State private var selection: OnboardingPage = .value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            pages
            footer
        }
        .background(Color(uiColor: .systemGroupedBackground))
        // `fullScreenCover`는 루트(`RootTabView`)의 `.tint`를 물려받지 않는다 — 안 걸면 "다음"
        // 버튼이 앱 어디에도 없는 시스템 파란색으로 뜬다(아이패드 시뮬레이터에서 확인).
        .tint(Theme.tint)
    }

    // MARK: - 3장

    private var pages: some View {
        TabView(selection: $selection) {
            ForEach(OnboardingPage.allCases) { page in
                pageContent(page)
                    .tag(page)
            }
        }
        // 시스템 기본 인디케이터를 끄고 아래 `pageIndicator`로 직접 그린다 — 기본 점은 밝은
        // 배경에서 거의 흰색이라 보이지 않았고(실기 확인), 색을 바꾸려면 `UIPageControl`의
        // 전역 appearance를 건드려야 해서 앱의 다른 화면까지 영향을 받는다.
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// 글자 크기를 키운 사용자(Dynamic Type)에게도 본문이 잘리지 않도록 각 장을 스크롤에 담는다 —
    /// 아이폰 세로에서 3단계 + 단서까지 있는 2장은 기본 크기에서도 여유가 많지 않다.
    private func pageContent(_ page: OnboardingPage) -> some View {
        GeometryReader { geometry in
            ScrollView {
                Theme.glassGroup {
                    VStack(spacing: Theme.Spacing.lg) {
                        symbolPlate(page)

                        VStack(spacing: Theme.Spacing.sm) {
                            Text(page.title)
                                .font(Theme.Typography.largeTitleBold)
                                .multilineTextAlignment(.center)
                            Text(page.body)
                                .font(Theme.Typography.body)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        if !page.steps.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                                ForEach(page.steps) { step in
                                    stepRow(step)
                                }
                            }
                            .padding(Theme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .harmonyGlassCard()
                        }

                        if let footnote = page.footnote {
                            Label(footnote, systemImage: "info.circle")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, Theme.Spacing.md)
                                .padding(.vertical, Theme.Spacing.sm)
                                // 단서도 같은 재질로 — 배경 없이 두면 이 한 조각만 종이처럼 뜬다.
                                .harmonyGlassCard()
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                // 아이패드처럼 세로가 남는 화면에서 내용이 위로 몰리고 아래가 텅 비지 않게,
                // 스크롤 내용의 최소 높이를 화면 높이로 잡아 세로 가운데에 놓는다. 글자 크기를
                // 키워 내용이 화면보다 길어지면 minHeight를 넘겨 평소처럼 스크롤된다.
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
        }
    }

    /// 장을 대표하는 심볼 — 맨몸으로 두지 않고 둥근 글래스 판 위에 올린다. 화면에서 가장 먼저
    /// 눈이 닿는 자리라 여기가 다른 재질이면 나머지 표면들과 따로 논다.
    private func symbolPlate(_ page: OnboardingPage) -> some View {
        Image(systemName: page.symbolName)
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(page == .value ? Theme.voiceAccent : Theme.tint)
            .frame(width: 108, height: 108)
            .harmonyGlass(in: Circle(), fallback: Color(uiColor: .secondarySystemGroupedBackground))
            // 바로 아래 제목이 같은 내용을 말하므로 VoiceOver가 두 번 읽지 않게 한다.
            .accessibilityHidden(true)
    }

    private func stepRow(_ step: OnboardingPage.Step) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: step.symbolName)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.label)
                    .font(Theme.Typography.subheadlineBold)
                Text(step.detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 라벨과 설명이 한 덩어리로 읽히게 묶는다(따로 읽으면 "부르기" 다음에 뜬금없는 문장이 온다).
        .accessibilityElement(children: .combine)
    }

    // MARK: - 하단(인디케이터 + 버튼)

    /// **세 장의 버튼 자리를 같은 높이로 고정한다.** 예전엔 건너뛰기가 화면 맨 위에 따로 있고
    /// 마지막 장에만 보조 버튼이 하나 더 있어서, 장을 넘길 때 주 버튼이 위아래로 튀었다.
    /// 모든 장을 "주 버튼 + 보조 버튼" 2단으로 맞추면 위치가 저절로 고정되고, 빠져나가는 출구도
    /// 화면 위아래로 흩어지지 않고 한자리에 모인다.
    private var footer: some View {
        Theme.glassGroup {
            VStack(spacing: Theme.Spacing.md) {
                pageIndicator

                VStack(spacing: Theme.Spacing.sm) {
                    Button {
                        primaryAction()
                    } label: {
                        Text(primaryTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .harmonyButtonStyle(prominent: true)

                    Button {
                        onFinish()
                    } label: {
                        Text(secondaryTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .harmonyButtonStyle()
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
    }

    private var primaryTitle: String {
        selection.requestsMicrophonePermission ? "마이크 허용하고 시작하기" : "다음"
    }

    /// 마지막 장에서만 문구가 달라진다 — 앞 두 장의 "건너뛰기"는 소개를 안 보겠다는 뜻이고,
    /// 마지막 장의 "나중에 할게요"는 권한을 지금 주지 않겠다는 뜻이라 하는 일이 다르다
    /// (동작은 둘 다 온보딩 종료로 같지만, 무엇을 거절하는지가 다르므로 말도 달라야 한다).
    private var secondaryTitle: String {
        selection.requestsMicrophonePermission ? "나중에 할게요" : "건너뛰기"
    }

    private func primaryAction() {
        if selection.requestsMicrophonePermission {
            requestMicrophonePermission()
        } else {
            advance()
        }
    }

    /// 직접 그리는 페이지 인디케이터.
    ///
    /// 시스템 기본은 밝은 배경에서 흰 점이라 사실상 안 보였다. 여기서는 앱 틴트를 쓰되 현재
    /// 페이지만 채도를 살리고 나머지는 흐리게 둬서, 색만이 아니라 **모양(현재 페이지는 길쭉한
    /// 알약)** 으로도 구분되게 한다 — 색 대비만으로 구분하면 색각 이상 사용자에게는 점 세 개가
    /// 다 같아 보인다.
    private var pageIndicator: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(OnboardingPage.allCases) { page in
                let isCurrent = page == selection
                Capsule()
                    .fill(isCurrent ? Theme.tint : Theme.tint.opacity(0.28))
                    .frame(width: isCurrent ? 26 : 9, height: 9)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .harmonyGlassCapsule()
        // 점 세 개가 각각 읽히면 아무 뜻도 안 된다 — 하나로 묶어 "몇 장 중 몇 장"으로 읽어준다.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(OnboardingPage.allCases.count)장 중 \(selection.rawValue + 1)장")
    }

    private func advance() {
        guard let next = OnboardingPage(rawValue: selection.rawValue + 1) else {
            onFinish()
            return
        }
        // Reduce Motion이 켜져 있으면 페이지가 옆으로 미끄러지는 대신 그냥 바뀌게 한다
        // (Apple 권장: 슬라이드 대신 크로스페이드/무전환).
        if reduceMotion {
            selection = next
        } else {
            withAnimation { selection = next }
        }
    }

    /// 시스템 팝업은 **여기서 처음 뜬다**. 앞 장에서 왜 필요한지 이미 말했으므로 사용자는
    /// 맥락을 알고 답하게 된다.
    ///
    /// 허용이든 거부든 온보딩은 끝낸다 — 거부한 사람을 이 화면에 붙잡아 두면 앱을 아예 못 쓰게
    /// 된다. 거부 상태는 연습 탭이 이미 전용 안내(`micPermissionDeniedContent`, "설정 열기")로
    /// 받아내고 있고, 권한을 다시 묻는 것도 그쪽 흐름(`beginCapturingIfNeeded`)이 맡는다.
    private func requestMicrophonePermission() {
        AVAudioApplication.requestRecordPermission { _ in
            DispatchQueue.main.async {
                onFinish()
            }
        }
    }
}
