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

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    static let cardCornerRadius: CGFloat = 16
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
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
        )
    }
}
