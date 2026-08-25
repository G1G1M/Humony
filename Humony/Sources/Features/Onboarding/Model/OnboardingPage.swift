import Foundation

/// 앱을 처음 켰을 때 한 번 보여주는 3장의 내용.
///
/// **왜 3장인가.** 이 앱은 "부르면 뭔가 일어나는" 종류라 설명보다 체험이 빠르다. 그래서
/// 가치(1장)와 흐름(2장)만 짧게 말하고 곧장 마이크 권한(3장)으로 넘어가 첫 녹음까지 데려간다.
/// 2장을 뺄까도 고민했지만, 그러면 콜앤리스폰스 제약("들려주는 동안엔 마이크가 쉰다")을 말할
/// 자리가 없어진다 — 그건 나중에 "왜 인식이 안 되지?"라는 혼란으로 반드시 돌아온다.
///
/// **여기에는 이론 용어를 한 개도 쓰지 않는다.** 온보딩에서 설명한 말은 실제로 그 말을 만나는
/// 몇 분 뒤에는 잊히기 때문이다. 용어는 등장하는 화면의 ⓘ(`GlossaryTerm`)가 맡는다.
/// 이 규칙은 취향이 아니라 계약이라 `OnboardingPageTests`가 금지어 목록으로 강제한다.
///
/// 문구를 뷰가 아니라 이 순수 타입에 두는 이유도 그 테스트 때문이다 — SwiftUI 뷰 안의
/// 문자열 리터럴은 테스트가 읽을 수 없다.
enum OnboardingPage: Int, CaseIterable, Identifiable {
    /// 무슨 앱인가 — 다른 악기 소리가 아니라 "내 목소리"라는 게 이 앱의 핵심 경험이다.
    case value
    /// 어떻게 쓰는가 — 3단계 + 콜앤리스폰스 제약.
    case flow
    /// 마이크 권한 pre-prompt — 시스템 팝업 **전에** 왜 필요한지 우리 화면에서 먼저 말한다.
    case microphone

    var id: Int { rawValue }

    /// 2장의 세 단계처럼 "아이콘 + 한 줄"로 늘어놓는 항목.
    struct Step: Identifiable {
        let symbolName: String
        let label: String
        let detail: String

        var id: String { label }
    }

    var symbolName: String {
        switch self {
        case .value: return "waveform"
        case .flow: return "list.number"
        case .microphone: return "mic.badge.plus"
        }
    }

    var title: String {
        switch self {
        case .value: return "부른 노래에 화음을 얹어 드려요"
        case .flow: return "이렇게 연습해요"
        case .microphone: return "마이크를 써도 될까요?"
        }
    }

    var body: String {
        switch self {
        case .value:
            return "한 소절만 부르면 어울리는 화음을 찾아내요. 그것도 다른 악기 소리가 아니라, 방금 부른 목소리 그대로요."
        case .flow:
            return "녹음 한 번이면 아래 세 가지가 이어서 일어나요."
        case .microphone:
            return "노래를 듣고 어떤 음인지 알아내려면 마이크가 필요해요. 녹음은 전부 이 기기 안에서 처리되고, 인터넷으로 어디에도 보내지 않아요."
        }
    }

    var steps: [Step] {
        switch self {
        case .flow:
            return [
                Step(symbolName: "mic.fill", label: "부르기", detail: "좋아하는 노래를 한 소절 불러요"),
                Step(symbolName: "waveform.path", label: "화음 듣기", detail: "만들어진 화음을 내 목소리로 들어봐요"),
                Step(symbolName: "checkmark.seal", label: "따라 부르기", detail: "골라 들은 소리를 따라 부르면 얼마나 맞았는지 알려드려요"),
            ]
        case .value, .microphone:
            return []
        }
    }

    /// 본문 아래에 작게 붙는 단서. 지금은 2장의 콜앤리스폰스 제약 하나뿐이다.
    var footnote: String? {
        switch self {
        case .flow:
            return "들려드리는 동안은 마이크가 잠시 쉬어요. 스피커에서 나온 소리가 마이크로 되돌아오면 내가 부른 걸로 잘못 알아듣거든요."
        case .value, .microphone:
            return nil
        }
    }

    /// 이 장이 시스템 권한 팝업을 띄우는 장인지. 마지막 장이어야 pre-prompt가 의미를 갖는다
    /// (왜 필요한지 다 읽은 뒤에 물어야 하니까).
    var requestsMicrophonePermission: Bool {
        self == .microphone
    }

    /// 금지어 검사용 — 이 장에서 사용자 눈에 닿는 모든 문자열을 한 덩어리로 잇는다.
    var allText: String {
        var parts = [title, body]
        parts += steps.flatMap { [$0.label, $0.detail] }
        if let footnote { parts.append(footnote) }
        return parts.joined(separator: "\n")
    }
}
