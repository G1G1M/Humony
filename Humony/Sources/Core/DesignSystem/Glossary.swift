import SwiftUI

/// 화면에 그대로 뜨는 낯선 말들의 짧은 설명 — 각 용어가 **등장하는 자리**에 ⓘ로 붙인다.
///
/// **왜 온보딩이 아니라 여기인가.** 앱을 처음 켠 사람에게 "가운뎃소리란 …"을 미리 설명해도,
/// 그 말을 실제로 만나는 건 녹음을 마친 몇 분 뒤다. 그때는 이미 잊는다. 그래서 온보딩
/// (`OnboardingPage`)은 용어를 **한 개도 쓰지 않고**, 대신 용어가 화면에 나오는 자리마다
/// 이 사전을 붙여 갚는다. 두 규칙이 짝이 돼야 `PRODUCT.md` 원칙 1(이론 지식 없이도 이해)이
/// 성립하고, 양쪽 다 테스트로 박혀 있다(`OnboardingPageTests`, `GlossaryTests`).
///
/// **왜 하필 이 다섯 개인가.** 화면 문자열을 훑어서 "설명 없이 노출되는 말"만 골랐다 —
/// `성부`(연습·기록 양쪽), `아랫/가운뎃/윗소리`(146절에 3도·5도를 대체한 자리 이름),
/// `조성`(분석 직후·기록 목록). cent는 주석에만 있고 화면에는 안 뜨므로 넣지 않았다.
enum GlossaryTerm: String, CaseIterable, Identifiable {
    case voice
    case bass
    case third
    case fifth
    case key

    var id: String { rawValue }

    /// 성부 라벨 옆에 ⓘ를 붙일 때, 라벨이 가리키는 용어를 바로 찾기 위한 다리.
    /// `ChordGenerator.Interval`에 케이스가 늘면 여기서 컴파일 에러가 나야 하므로 switch로 둔다.
    init?(interval: ChordGenerator.Interval) {
        switch interval {
        case .bass: self = .bass
        case .third: self = .third
        case .fifth: self = .fifth
        }
    }

    /// 팝오버 제목 — 화면에 실제로 쓰이는 표기를 그대로 쓴다(다른 이름을 지어내면 연결이 끊긴다).
    var title: String {
        switch self {
        case .voice: return "성부"
        case .bass: return ChordGenerator.Interval.bass.koreanLabel
        case .third: return ChordGenerator.Interval.third.koreanLabel
        case .fifth: return ChordGenerator.Interval.fifth.koreanLabel
        case .key: return "조성"
        }
    }

    /// 팝오버 한 장에 들어가는 분량(20~120자, `GlossaryTests`가 강제)으로 쓴다.
    /// 거리는 이론 이름 대신 계이름으로 옮긴다 — 읽는 사람이 그 자리에서 불러볼 수 있게.
    var explanation: String {
        switch self {
        case .voice:
            return "화음을 이루는 소리 갈래 하나를 뜻해요. 이 앱은 부른 멜로디에 아래·가운데·위 세 갈래를 얹어 줘요."
        case .bass:
            return "세 갈래 중 가장 낮게 깔리는 소리예요. 노래의 바닥을 받쳐 주는 자리라 든든하게 들려요."
        case .third:
            return "부른 음에서 두 칸 위(도→미)에 얹는 소리예요. 화음이 밝게 들릴지 어둡게 들릴지를 이 소리가 정해요."
        case .fifth:
            return "부른 음에서 네 칸 위(도→솔)에 얹는 소리예요. 화음을 넓고 단단하게 채워 줘요."
        case .key:
            return "노래 전체가 기대고 있는 기준 음이에요. 이걸 알아야 어울리는 화음을 고를 수 있어서 녹음이 끝나면 먼저 찾아내요."
        }
    }
}

/// 용어 옆에 붙이는 ⓘ 버튼 — 탭하면 설명이 팝오버로 뜬다.
///
/// 아이폰(컴팩트)에서 `.popover`는 기본적으로 시트로 승격돼 화면 절반을 덮는다. 두 줄짜리
/// 설명에 그건 과해서 `presentationCompactAdaptation(.popover)`로 아이폰에서도 작은 팝오버를
/// 유지한다 — 원래 보던 화면이 가려지지 않아야 "이 라벨이 뭐지"를 확인하고 바로 돌아올 수 있다.
struct GlossaryTip: View {
    let term: GlossaryTerm
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        // 아이콘만 있는 버튼이라 VoiceOver에는 무슨 용어의 설명인지까지 읽어 줘야 한다.
        .accessibilityLabel("\(term.title) 설명")
        .accessibilityHint("무슨 뜻인지 알려드려요")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(term.title)
                    .font(Theme.Typography.subheadlineBold)
                Text(term.explanation)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: 260)
            .presentationCompactAdaptation(.popover)
        }
    }
}
