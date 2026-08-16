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
    @ViewBuilder let content: Content

    init(_ title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.title3.bold())

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
