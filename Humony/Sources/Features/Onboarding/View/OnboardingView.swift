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
/// **앱이 그리는 표면은 리퀴드 글래스로 통일한다.** 심볼 판, 3단계 카드, 단서, 버튼(주/건너뛰기)이
/// 같은 재질 체계(`Theme`의 glass 헬퍼)를 쓰고, 한 화면의 글래스 조각들은 `Theme.glassGroup`
/// (iOS 26의 `GlassEffectContainer`)으로 묶어 서로의 굴절에 반응하게 한다 — 조각마다 따로 두면
/// 같은 재질인데도 미묘하게 다른 표면처럼 보인다.
///
/// 다만 **페이지 인디케이터는 애플 기본 컴포넌트를 그대로 쓴다**(색만 앱 틴트로 잡는다). 한 번
/// 직접 그려봤다가 되돌렸다 — 사용자가 어디서든 같은 모양으로 알아보는 표준 컨트롤을 손으로
/// 다시 만들면, 그럴듯해 보여도 결국 "이 앱에만 있는 낯선 것"이 된다.
struct OnboardingView: View {
    /// 3장을 다 지났거나 건너뛰었을 때. 어느 쪽이든 완료로 친다(`OnboardingGate.markCompleted`).
    let onFinish: () -> Void

    @State private var selection: OnboardingPage = .value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            skipBar
            pages
            footer
        }
        // 기본 페이지 인디케이터는 시스템 기본색(밝은 배경에서 거의 흰색)이라 눈에 안 들어온다.
        // 컴포넌트는 애플 것을 그대로 쓰되 색만 앱 틴트로 바꾼다 — 이건 UIKit 전역 appearance라
        // 온보딩이 떠 있는 동안에만 걸고 사라질 때 되돌려서, 나중에 다른 화면이 페이지 뷰를
        // 쓰게 되더라도 여기서 칠한 색을 물려받지 않게 한다.
        .onAppear {
            UIPageControl.appearance().currentPageIndicatorTintColor = UIColor(Theme.tint)
            UIPageControl.appearance().pageIndicatorTintColor = UIColor(Theme.tint.opacity(0.25))
        }
        .onDisappear {
            UIPageControl.appearance().currentPageIndicatorTintColor = nil
            UIPageControl.appearance().pageIndicatorTintColor = nil
        }
        .background(Color(uiColor: .systemGroupedBackground))
        // `fullScreenCover`는 루트(`RootTabView`)의 `.tint`를 물려받지 않는다 — 안 걸면 "다음"
        // 버튼이 앱 어디에도 없는 시스템 파란색으로 뜬다(아이패드 시뮬레이터에서 확인).
        .tint(Theme.tint)
    }

    // MARK: - 건너뛰기

    /// 원래 자리인 우상단. 마지막 장에는 아래에 "나중에 할게요"가 따로 있어서 숨긴다 —
    /// 같은 뜻의 출구가 한 화면에 둘이면 어느 쪽이 무엇인지 읽는 데 시간이 든다.
    /// 자리는 항상 차지하므로(고정 높이) 숨겨도 아래 내용이 밀리지 않는다.
    ///
    /// 탭 타깃은 44×44 아래로 내려가지 않게 잡는다(HIG 최소 규격, 앱의 다른 아이콘 버튼들과
    /// 같은 관용구다). 화면 가장자리에 홀로 있는 작은 버튼이라 여기가 작으면 특히 잘 빗나간다.
    private var skipBar: some View {
        HStack {
            Spacer()
            if selection != .microphone {
                // `harmonyButtonStyle()`(iOS 26의 `.glass`)을 쓰지 않고 캡슐을 직접 그린다 —
                // 그 스타일은 `controlSize`로만 높이가 정해져서, 라벨이든 버튼이든 `.frame`을
                // 걸어도 캡슐은 28pt에 머물렀다(실측). `.large`로 올리면 44를 넘지만 이번엔
                // 주 버튼과 같은 덩치가 되어 보조 버튼의 무게가 사라진다. 재질은 같은 헬퍼
                // (`harmonyGlassCapsule`)를 쓰므로 다른 표면들과 그대로 한 벌이다.
                Button {
                    onFinish()
                } label: {
                    Text("건너뛰기")
                        .font(Theme.Typography.subheadline)
                        // `.plain`은 라벨 색을 건드리지 않아 글자가 검게 남는다 — 누를 수 있는
                        // 것으로 보이도록 틴트를 직접 준다(버튼 스타일이 해주던 일이다).
                        .foregroundStyle(Theme.tint)
                        .padding(.horizontal, Theme.Spacing.md)
                        // 높이는 HIG 최소 탭 타깃(44)에 정확히 맞추고, 폭은 글자에 맡겨
                        // 보조 버튼다운 크기를 지킨다.
                        .frame(minWidth: 44, minHeight: 44)
                        .harmonyGlassCapsule()
                }
                .buttonStyle(.plain)
            }
        }
        // 버튼(최소 44)에 위아래 숨 쉴 자리를 더한 높이 — 이 바는 버튼이 숨는 마지막 장에도
        // 같은 높이를 유지해야 아래 내용이 밀리지 않는다.
        .frame(height: 60)
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
        // 인디케이터는 애플 기본 컴포넌트를 그대로 쓴다(색만 위 onAppear에서 잡아준다).
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
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

                            // 본문은 문장마다 따로 그린다 — 한 덩어리로 두면 줄바꿈이 문장
                            // 한가운데를 잘라 "…녹음은 전부 이 / 기기 안에서"처럼 읽다가
                            // 한 번 멈추게 된다(`OnboardingPage.bodyParagraphs` 주석 참고).
                            VStack(spacing: Theme.Spacing.xs) {
                                ForEach(page.bodyParagraphs, id: \.self) { paragraph in
                                    Text(paragraph)
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            // 본문만 제목보다 좁게 잡는다 — 글자가 작아서 같은 폭을 주면 한 줄이
                            // 너무 길어지고(아이패드에서 특히), 줄이 어중간한 자리에서 떨어진다.
                            .frame(maxWidth: 420)
                            // 한글은 행간이 붙으면 답답해 보인다.
                            .lineSpacing(4)
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

                        if !page.footnoteLines.isEmpty {
                            // `Label` 한 덩어리로는 줄을 세울 수 없어서 아이콘과 글을 직접 붙인다.
                            // 아이콘은 첫 줄에 맞춰 위로 정렬한다 — 가운데 정렬하면 줄이 늘어날수록
                            // 아이콘이 글 한복판으로 내려와 무엇을 가리키는지 흐려진다.
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                                Image(systemName: "info.circle")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(page.footnoteLines, id: \.self) { line in
                                        Text(line)
                                            .font(Theme.Typography.caption)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            // 줄을 나눠 그려도 VoiceOver에는 한 문장으로 읽혀야 한다.
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(page.footnote ?? "")
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

    // MARK: - 하단 버튼

    /// **주 버튼은 세 장 모두 같은 자리에 있어야 한다.** 마지막 장에만 있는 "나중에 할게요"를
    /// 그냥 아래에 붙이면 그 높이만큼 주 버튼이 위로 밀려서, 장을 넘길 때 버튼이 위아래로 튄다.
    /// 그래서 보조 버튼 자리를 **항상 같은 높이로 예약**하고 마지막 장에서만 채운다.
    ///
    /// 보조 버튼은 주 버튼과 같은 크기로 만들지 않는다 — 둘이 같은 무게로 놓이면 "지금 무엇을
    /// 하면 되는지"가 흐려진다. 권한을 주는 쪽이 주된 길이고, 미루는 쪽은 언제나 열려 있는
    /// 작은 문이다.
    private var footer: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button {
                primaryAction()
            } label: {
                Text(primaryTitle)
                    .frame(maxWidth: .infinity)
            }
            .harmonyButtonStyle(prominent: true)
            .controlSize(.large)

            ZStack {
                if selection.requestsMicrophonePermission {
                    Button("나중에 할게요") { onFinish() }
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            // 마지막 장에만 버튼이 들어가지만 자리는 늘 차지한다 — 그래야 위의 주 버튼이
            // 세 장 모두 같은 높이에 놓인다.
            .frame(height: 32)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
    }

    private var primaryTitle: String {
        selection.requestsMicrophonePermission ? "마이크 허용하고 시작하기" : "다음"
    }

    private func primaryAction() {
        if selection.requestsMicrophonePermission {
            requestMicrophonePermission()
        } else {
            advance()
        }
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
