import XCTest
@testable import Humony

/// 온보딩 3장의 **내용 계약**을 고정한다.
///
/// 여기서 지키는 건 문구의 미적 취향이 아니라 `PRODUCT.md` 원칙 1("음악 이론 지식이 없어도
/// 이해 가능해야 한다")이다. 온보딩은 앱을 처음 켠 사람이 보는 화면이라, 여기에 설명 없는
/// 이론 용어가 하나라도 새어들면 그 원칙이 첫 화면에서부터 깨진다.
///
/// 사람 눈으로 지키면 문구를 고칠 때마다 다시 놓친다 — 그래서 금지어 목록을 테스트로 박는다.
/// **용어를 쓰고 싶으면 온보딩이 아니라 `Glossary`(등장하는 화면의 ⓘ)에 넣는 게 이 앱의 규칙이다.**
final class OnboardingPageTests: XCTestCase {

    /// 온보딩 본문에 나오면 안 되는 말들 — 전부 "설명 없이 던지면 첫 사용자가 막히는" 용어다.
    /// `화음`은 뺐다(일상어로 통하고, 이 앱을 한 문장으로 설명하려면 반드시 필요하다).
    private let bannedTerms = [
        "화성", "3도", "5도", "센트", "cent", "조성", "온음계", "근음", "성부", "피치", "MIDI", "Hz",
    ]

    func testPageCountAndOrder() {
        // 3장 고정 — 늘리고 싶어지면 "체험이 설명보다 빠른 앱"이라는 판단부터 다시 할 것.
        XCTAssertEqual(OnboardingPage.allCases.count, 3)
        XCTAssertEqual(OnboardingPage.allCases, [.value, .flow, .microphone])
    }

    func testMicrophonePageIsLast() {
        // 권한 요청이 마지막이어야 하는 이유: 왜 필요한지 설명(1·2장)을 다 읽은 뒤에 물어야
        // pre-prompt가 의미를 갖는다. 순서가 뒤집히면 지금의 "예고 없는 팝업"과 다를 게 없다.
        XCTAssertEqual(OnboardingPage.allCases.last, .microphone)
        XCTAssertTrue(OnboardingPage.microphone.requestsMicrophonePermission)
        XCTAssertFalse(OnboardingPage.value.requestsMicrophonePermission)
        XCTAssertFalse(OnboardingPage.flow.requestsMicrophonePermission)
    }

    func testBodyIsKeptAsSentencesForCleanLineBreaks() {
        // 본문을 문장 단위로 갖는 건 취향이 아니라 줄바꿈 계약이다 — 뷰가 문장마다 Text를
        // 따로 그려야 "…녹음은 전부 이 / 기기 안에서"처럼 문장 한가운데가 잘리지 않는다.
        for page in OnboardingPage.allCases {
            XCTAssertFalse(page.bodyParagraphs.isEmpty, "\(page)에 본문 문장이 없다")
            for paragraph in page.bodyParagraphs {
                XCTAssertFalse(paragraph.isEmpty, "\(page)에 빈 문장이 있다")
            }
        }
    }

    func testBodyJoinsItsParagraphs() {
        // `body`(금지어 검사 등에서 쓰는 한 덩어리)와 실제로 그려지는 문장들이 갈라지면,
        // 테스트가 통과하는데 화면에는 다른 문구가 뜨는 상태가 된다.
        for page in OnboardingPage.allCases {
            for paragraph in page.bodyParagraphs {
                XCTAssertTrue(page.body.contains(paragraph), "\(page)의 body가 문장을 빠뜨렸다")
            }
        }
    }

    /// 문구에 `\n`을 직접 박으면 지금 이 폭에서만 예쁘다 — Dynamic Type을 키우거나 좁은
    /// 화면에서는 박아둔 줄이 또 접혀 오히려 더 망가진다. 줄을 나누고 싶으면 문장을
    /// `bodyParagraphs`에 하나 더 넣을 것.
    func testCopyHasNoHardCodedLineBreaks() {
        for page in OnboardingPage.allCases {
            var strings = [page.title] + page.bodyParagraphs
            strings += page.steps.flatMap { [$0.label, $0.detail] }
            if let footnote = page.footnote { strings.append(footnote) }
            for text in strings {
                XCTAssertFalse(
                    text.contains("\n"),
                    "\(page) 문구에 줄바꿈이 박혀 있다 — 문장을 나누는 방식으로 바꿀 것"
                )
            }
        }
    }

    func testEveryPageHasTitleAndBody() {
        for page in OnboardingPage.allCases {
            XCTAssertFalse(page.title.isEmpty, "\(page)에 제목이 없다")
            XCTAssertFalse(page.body.isEmpty, "\(page)에 본문이 없다")
            XCTAssertFalse(page.symbolName.isEmpty, "\(page)에 심볼이 없다")
        }
    }

    /// 이 테스트가 이 파일의 존재 이유다.
    func testNoUnexplainedJargonAnywhereInOnboarding() {
        for page in OnboardingPage.allCases {
            let text = page.allText
            for term in bannedTerms {
                XCTAssertFalse(
                    text.contains(term),
                    "\(page) 문구에 설명 없는 용어 '\(term)'이 들어갔다 — 온보딩 대신 Glossary(ⓘ)로 옮길 것"
                )
            }
        }
    }

    func testFlowPageHasThreeSteps() {
        // 부르기 → 화음 듣기 → 따라 부르기. 앱의 실제 파이프라인과 개수가 어긋나면
        // 온보딩이 거짓말을 하게 된다.
        XCTAssertEqual(OnboardingPage.flow.steps.count, 3)
        for step in OnboardingPage.flow.steps {
            XCTAssertFalse(step.label.isEmpty)
            XCTAssertFalse(step.detail.isEmpty)
            XCTAssertFalse(step.symbolName.isEmpty)
        }
    }

    func testOnlyFlowPageHasSteps() {
        XCTAssertTrue(OnboardingPage.value.steps.isEmpty)
        XCTAssertTrue(OnboardingPage.microphone.steps.isEmpty)
    }

    /// 콜앤리스폰스 제약(재생 중엔 마이크가 쉰다)은 나중에 "왜 인식이 안 되지?"로 돌아올
    /// 혼란이라 2장에서 미리 말해둔다 — `PRODUCT.md`의 Operating Context가 그 근거다.
    func testFlowPageMentionsCallAndResponseConstraint() {
        XCTAssertTrue(OnboardingPage.flow.footnote?.contains("마이크") == true)
    }

    /// 단서도 본문과 같은 줄바꿈 계약을 따른다 — 화면에 그려지는 건 줄 배열 쪽이고,
    /// `footnote`(한 덩어리)는 금지어 검사와 VoiceOver용이다. 둘이 갈라지면 테스트는
    /// 통과하는데 화면에는 다른 문구가 뜬다.
    func testFootnoteJoinsItsLines() {
        for page in OnboardingPage.allCases {
            if page.footnoteLines.isEmpty {
                XCTAssertNil(page.footnote, "\(page)에 줄이 없는데 단서가 남아 있다")
            } else {
                for line in page.footnoteLines {
                    XCTAssertFalse(line.isEmpty, "\(page) 단서에 빈 줄이 있다")
                    XCTAssertTrue(
                        page.footnote?.contains(line) == true,
                        "\(page)의 footnote가 줄을 빠뜨렸다"
                    )
                }
            }
        }
    }

    /// 서버가 없다는 건 이 앱의 실제 사실이고(전 과정 온디바이스), 권한을 묻는 자리에서
    /// 가장 설득력 있는 근거다. 문구가 사라지면 pre-prompt의 알맹이가 빠진다.
    func testMicrophonePageExplainsOnDeviceProcessing() {
        let text = OnboardingPage.microphone.allText
        XCTAssertTrue(text.contains("기기"), "온디바이스 처리 설명이 빠졌다")
    }
}
