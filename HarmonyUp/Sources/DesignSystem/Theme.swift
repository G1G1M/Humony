import SwiftUI

/// 이 앱의 디자인 토큰(색/간격) 모음.
///
/// 색상 원칙: iOS HIG는 "하나의 틴트 컬러가 인터랙션 요소를 이끈다"고 명시한다 — 그래서 버튼
/// 틴트는 `tint` 하나만 쓰고, 두 번째 브랜드색(`voiceAccent`, "내 목소리로 화음" 계열)은 버튼이
/// 아니라 아이콘/라벨 같은 장식에만 쓴다. 배경/카드 같은 나머지 색은 새로 만들지 않고
/// `.secondarySystemGroupedBackground`처럼 이미 라이트/다크 양쪽에 자동 대응하는 시스템 시맨틱
/// 색을 그대로 쓴다 — 커스텀 hex는 시스템이 모르는 색이라 다크모드/고대비 대응이 깨지기 쉽다.
enum Theme {

    /// 앱 전역의 유일한 인터랙션 틴트. 시스템 시맨틱 색 중엔 이 브랜드 톤(청보라)이 없어서
    /// 라이트/다크 각각의 값을 직접 정의한다 — 다크모드에서 더 밝게(채도는 유지) 하는 건
    /// 시스템 블루(라이트 #007AFF -> 다크 #0A84FF)와 같은 패턴을 따른 것이다.
    static let tint = Color(
        light: Color(red: 0.35, green: 0.35, blue: 0.84),
        dark: Color(red: 0.52, green: 0.52, blue: 0.94)
    )

    /// "내 목소리로 화음" 계열의 아이콘/라벨에만 쓰는 장식색 — 합성음 재생과 시각적으로
    /// 구분하기 위한 것이지, 버튼 틴트로 쓰지 않는다(위 색상 원칙 참고).
    static let voiceAccent = Color(
        light: Color(red: 0.94, green: 0.42, blue: 0.36),
        dark: Color(red: 1.0, green: 0.54, blue: 0.45)
    )

    /// 채점(정확/부정확) 상태색 — 시스템 시맨틱 green/red를 그대로 쓰되, 앱 안에서
    /// "이 색은 피치 정확도를 뜻한다"는 의미를 이름으로 명확히 한다.
    static let pitchGood = Color(uiColor: .systemGreen)
    static let pitchBad = Color(uiColor: .systemRed)

    /// 경고/주의 문구 색 — "약점 화성 안내"(HistoryView) 등에 흩어져 쓰이던 `.orange` 리터럴을
    /// 이름 붙은 토큰으로 승격했다(다른 시맨틱 색들처럼 "이 색이 무슨 의미인지" 한 곳에서
    /// 관리하기 위함, 크리틱 Minor Observations 정리).
    static let warning = Color(uiColor: .systemOrange)

    /// 성부(베이스/3도/5도)마다 고정된 정체성 색 — 인터랙션 틴트(`tint`)와는 다른 목적이다.
    /// HIG 원칙("하나의 틴트가 인터랙션을 이끈다")을 지키기 위해 **버튼에는 절대 안 쓰고**,
    /// 텍스트/차트 범례처럼 순수 장식·식별 용도로만 쓴다(`voiceAccent`와 같은 원칙). 채점
    /// 상태색(pitchGood 초록/pitchBad 빨강)이나 위 `warning`(주황)과도 겹치지 않게 골랐다 —
    /// 이 색이 "정확/부정확/주의"라는 상태 의미로 오해되면 안 되고, 순수하게 "이게 몇 도
    /// 성부인지"만 가리켜야 한다. HistoryView의 정확도 추이 차트와 PracticeView의 채점 패널
    /// 라벨이 같은 색으로 이어져서, 두 화면을 오갈 때도 "이건 3도 얘기구나"를 색으로 먼저
    /// 알아챌 수 있게 한다.
    static func intervalColor(for interval: ChordGenerator.Interval) -> Color {
        switch interval {
        case .bass: return .blue
        case .third: return .teal
        case .fifth: return .purple
        }
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    static let cardCornerRadius: CGFloat = 16

    /// 직접 그린 원형 버튼(녹음/정지/취소처럼 `Circle`을 손으로 채우던 곳)에 iOS 26+에서는
    /// 리퀴드 글래스 재질+색조를, 그 이전 버전에서는 기존처럼 단색 채우기를 쓴다. 배포
    /// 타깃(17.0)을 올리지 않고도 최신 기기에서만 리퀴드 글래스를 쓰기 위한 조건부 분기 —
    /// "이 앱의 모든 디자인 컴포넌트는 리퀴드 글래스를 쓰라"는 요청에 대응.
    @ViewBuilder
    static func glassCircle(tint: Color, diameter: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            Circle()
                .fill(.clear)
                .glassEffect(.regular.tint(tint).interactive(), in: Circle())
                .frame(width: diameter, height: diameter)
        } else {
            Circle()
                .fill(tint)
                .frame(width: diameter, height: diameter)
        }
    }

    /// 리퀴드 글래스 요소 여러 개가 가까이 모여 있는 묶음을 감싸는 **네이티브 컨테이너**
    /// (`GlassEffectContainer`). 배포 타깃(17.0)을 올리지 않으려고 조건부로 감싼다 — 이전
    /// 버전에서는 컨테이너 없이 내용만 그대로 통과시킨다.
    ///
    /// **왜 필요한가**: 글래스는 뒤에 있는 것을 실시간으로 굴절/블러해서 그리는 재질이라,
    /// 낱개로 쓰면 요소마다 따로 배경을 샘플링한다. 애플이 여러 글래스 요소를 컨테이너로
    /// 묶으라고 안내하는 이유가 둘이다 — (1) 묶인 요소들이 **하나의 유리판처럼** 서로를
    /// 인식해 가까워지면 자연스럽게 섞이고(낱개일 때는 각자 따로 놀아 경계가 딱딱하게 보인다),
    /// (2) 샘플링을 한 번으로 합쳐 **GPU 비용이 요소 수만큼 늘지 않는다**.
    ///
    /// 두 번째 이유가 이 앱에서는 특히 중요하다: 84·88절에서 "재생 중 웹뷰 렌더와 오디오가
    /// CPU를 다퉈 소리가 밀린다"를 실제로 겪었고, 조작부에는 글래스 버튼이 최대 9개까지
    /// (재생 1 + 성부 4행 × 2) 한 화면에 깔린다 — 녹음/재생 중에 그만큼의 실시간 블러가
    /// 각자 돌면 같은 계열 문제가 재발할 수 있다.
    @ViewBuilder
    static func glassGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { content() }
        } else {
            content()
        }
    }
}

extension View {
    /// 카드형 배경(모서리 둥근 사각형)에 iOS 26+에서는 리퀴드 글래스를, 그 이전에서는 기존
    /// 시스템 시맨틱 배경색을 쓴다.
    func harmonyGlassCard(cornerRadius: CGFloat = Theme.cardCornerRadius) -> some View {
        harmonyGlass(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            fallback: Color(uiColor: .secondarySystemGroupedBackground)
        )
    }

    /// 알약(캡슐) 모양 표면 — 녹음 중 타이머 배지처럼 콘텐츠 위에 떠 있는 작은 조각에 쓴다.
    /// 예전엔 `.ultraThinMaterial`을 썼는데, 그건 리퀴드 글래스 이전 세대의 재질이라 같은
    /// 화면의 다른 글래스 표면과 굴절/반사가 미묘하게 다르게 보인다 — 표면은 전부 같은
    /// 재질 체계로 통일한다(iOS 26 미만에서는 그대로 `.ultraThinMaterial`로 남는다).
    @ViewBuilder
    func harmonyGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// 임의의 도형에 리퀴드 글래스를 입히는 공통 구현 — 위 두 헬퍼가 도형만 바꿔 재사용한다.
    @ViewBuilder
    func harmonyGlass<S: Shape>(in shape: S, fallback: Color) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }

    /// `.bordered`/`.borderedProminent` 대신 iOS 26+에서는 리퀴드 글래스 버튼 스타일
    /// (`.glass`/`.glassProminent`)을 쓴다 — 앱 전역 버튼에 일괄 적용하는 용도.
    @ViewBuilder
    func harmonyButtonStyle(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

extension Theme {
    /// Pretendard로 통일한 타이포그래피. 실시간 숫자 표시(Hz/cent/시간 등 `design: .monospaced`로
    /// 쓰는 값)는 자릿수가 흔들리지 않아야 해서 예외적으로 시스템 모노스페이스 폰트를 그대로
    /// 쓴다 — 그 외 나머지 텍스트는 전부 여기서 정의한 Pretendard 폰트를 쓴다.
    enum Typography {
        // "빠른 녹음" 대기 화면처럼 화면 하나를 텍스트 한 줄이 주도하는 히어로 순간 전용 —
        // 카드 제목(title3Bold)보다 한 단계 더 큰, 유일한 largeTitle 크기 토큰.
        static let largeTitleBold = font(.largeTitle, weight: .bold)
        static let title3Bold = font(.title3, weight: .bold)
        static let headline = font(.headline, weight: .semibold)
        static let subheadline = font(.subheadline, weight: .regular)
        static let subheadlineBold = font(.subheadline, weight: .bold)
        static let body = font(.body, weight: .regular)
        static let caption = font(.caption, weight: .regular)
        static let caption2 = font(.caption2, weight: .regular)

        /// `relativeTo:`로 시스템 텍스트 스타일에 상대적으로 스케일되게 해서, 커스텀 폰트를 써도
        /// 사용자가 설정에서 글자 크기(Dynamic Type)를 키우면 이 폰트도 같이 커지게 한다.
        static func font(_ style: Font.TextStyle, weight: Font.Weight) -> Font {
            .custom(fontName(for: weight), size: basePointSize(for: style), relativeTo: style)
        }

        private static func fontName(for weight: Font.Weight) -> String {
            switch weight {
            case .bold, .heavy, .black: return "Pretendard-Bold"
            case .semibold: return "Pretendard-SemiBold"
            case .medium: return "Pretendard-Medium"
            default: return "Pretendard-Regular"
            }
        }

        // Apple HIG가 각 텍스트 스타일에 쓰는 기본 포인트 크기(라이트 사이즈 카테고리 기준)를
        // 그대로 따른다 — relativeTo:가 여기서부터 Dynamic Type 배율을 적용한다.
        private static func basePointSize(for style: Font.TextStyle) -> CGFloat {
            switch style {
            case .largeTitle: return 34
            case .title: return 28
            case .title2: return 22
            case .title3: return 20
            case .headline: return 17
            case .subheadline: return 15
            case .body: return 17
            case .callout: return 16
            case .footnote: return 13
            case .caption: return 12
            case .caption2: return 11
            @unknown default: return 17
            }
        }
    }
}

extension Color {
    /// 라이트/다크에서 각각 다른 색을 쓰는 커스텀 색을 만든다. 시스템 시맨틱 색이 없는
    /// 브랜드 컬러(위 `tint`, `voiceAccent`)에만 이 방식을 쓰고, 나머지는 시스템 시맨틱 색을 쓴다.
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// 화면의 각 기능 단위(실시간 피치, 조성+화음, 채점 등)를 감싸는 공용 카드 컨테이너.
/// 기존 `flowSection`의 후속 — 1~5 번호는 더 이상 쓰지 않는다. 지금은 측정→조성→화음→채점
/// 순서가 자연스럽지만, 이 순서 자체가 항상 고정된 정보는 아니므로(예: 나중에 "내 목소리로
/// 화음" 카드가 더 중요해질 수 있음) 카드마다 번호를 매기지 않고 제목만으로 구분한다.
struct HarmonyCard<Content: View>: View {
    let title: String
    let systemImage: String?
    /// 카드 제목 아이콘 색. nil이면 기본(`.primary`) — "내 목소리로 화음" 카드처럼 아이콘만으로
    /// 다른 계열임을 표시하고 싶을 때만 `Theme.voiceAccent`를 넘긴다(버튼 틴트는 건드리지 않는다).
    let iconColor: Color?
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String? = nil, iconColor: Color? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.iconColor = iconColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(iconColor ?? .primary)
                }
                Text(title)
            }
            .font(Theme.Typography.title3Bold)

            content
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .harmonyGlassCard()
    }
}
