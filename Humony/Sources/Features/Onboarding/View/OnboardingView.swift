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
struct OnboardingView: View {
    /// 3장을 다 지났거나 건너뛰었을 때. 어느 쪽이든 완료로 친다(`OnboardingGate.markCompleted`).
    let onFinish: () -> Void

    @State private var selection: OnboardingPage = .value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            skipBar
            pages
            actions
        }
        .background(Color(uiColor: .systemGroupedBackground))
        // `fullScreenCover`는 루트(`RootTabView`)의 `.tint`를 물려받지 않는다 — 안 걸면 "다음"
        // 버튼이 앱 어디에도 없는 시스템 파란색으로 뜬다(아이패드 시뮬레이터에서 확인).
        .tint(Theme.tint)
    }

    // MARK: - 건너뛰기

    /// 마지막 장에는 "나중에 할게요"가 따로 있어서 상단 건너뛰기를 숨긴다 — 같은 뜻의 출구가
    /// 한 화면에 둘이면 어느 쪽이 무엇인지 읽는 데 시간이 든다.
    @ViewBuilder
    private var skipBar: some View {
        HStack {
            Spacer()
            if selection != .microphone {
                Button("건너뛰기") { onFinish() }
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - 3장

    private var pages: some View {
        TabView(selection: $selection) {
            ForEach(OnboardingPage.allCases) { page in
                pageContent(page)
                    .tag(page)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
    }

    /// 글자 크기를 키운 사용자(Dynamic Type)에게도 본문이 잘리지 않도록 각 장을 스크롤에 담는다 —
    /// 아이폰 세로에서 3단계 + 단서까지 있는 2장은 기본 크기에서도 여유가 많지 않다.
    private func pageContent(_ page: OnboardingPage) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: Theme.Spacing.lg) {
                    Image(systemName: page.symbolName)
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(page == .value ? Theme.voiceAccent : Theme.tint)
                        // 바로 아래 제목이 같은 내용을 말하므로 VoiceOver가 두 번 읽지 않게 한다.
                        .accessibilityHidden(true)

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
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
                // 페이지 인디케이터가 본문을 가리지 않도록 아래를 비운다.
                .padding(.bottom, Theme.Spacing.xl)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                // 아이패드처럼 세로가 남는 화면에서 내용이 위로 몰리고 아래가 텅 비지 않게,
                // 스크롤 내용의 최소 높이를 화면 높이로 잡아 세로 가운데에 놓는다. 글자 크기를
                // 키워 내용이 화면보다 길어지면 minHeight를 넘겨 평소처럼 스크롤된다.
                .frame(minHeight: geometry.size.height, alignment: .center)
            }
        }
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

    // MARK: - 하단 버튼

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if selection.requestsMicrophonePermission {
                Button {
                    requestMicrophonePermission()
                } label: {
                    Text("마이크 허용하고 시작하기")
                        .frame(maxWidth: .infinity)
                }
                .harmonyButtonStyle(prominent: true)

                Button("나중에 할게요") { onFinish() }
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    advance()
                } label: {
                    Text("다음")
                        .frame(maxWidth: .infinity)
                }
                .harmonyButtonStyle(prominent: true)
            }
        }
        .controlSize(.large)
        .frame(maxWidth: 520)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
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
