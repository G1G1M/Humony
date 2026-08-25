import XCTest
@testable import Humony

/// 화면 곳곳의 ⓘ가 보여줄 용어 설명을 고정한다.
///
/// 온보딩(`OnboardingPageTests`)이 "첫 화면에 용어를 쓰지 않는다"를 지킨다면, 이쪽은 그 반대편
/// 계약을 지킨다 — **용어가 실제로 화면에 나오는 자리에는 반드시 설명이 붙어 있어야 한다.**
/// 둘이 짝이 돼야 `PRODUCT.md` 원칙 1이 성립한다(온보딩에서 안 쓴 만큼, 등장하는 자리에서 갚는다).
final class GlossaryTests: XCTestCase {

    /// 설명이 또 다른 미설명 용어로 도망가는 것을 막는다. "가운뎃소리란 화성의 근음 위에 쌓는
    /// 온음계 3음이다" 같은 문장은 사전으로서 아무 일도 하지 않는다.
    ///
    /// `성부`는 뺐다 — 이 사전 자체에 `.voice` 항목으로 들어 있어서, 다른 항목이 그 말을
    /// 쓰는 건 도망이 아니라 상호참조다.
    private let bannedInExplanations = ["화성", "온음계", "근음", "다이아토닉", "인터벌", "3도", "5도"]

    func testEveryVoiceIntervalHasATerm() {
        // 악보/재생/채점 화면에 실제로 뜨는 세 성부 라벨은 빠짐없이 설명이 있어야 한다.
        for interval in ChordGenerator.Interval.allCases {
            XCTAssertNotNil(
                GlossaryTerm(interval: interval),
                "\(interval) 라벨이 화면에 뜨는데 설명이 없다"
            )
        }
    }

    func testEveryTermHasTitleAndExplanation() {
        for term in GlossaryTerm.allCases {
            XCTAssertFalse(term.title.isEmpty, "\(term)에 제목이 없다")
            XCTAssertFalse(term.explanation.isEmpty, "\(term)에 설명이 없다")
        }
    }

    /// 팝오버 한 장에 들어가야 하는 분량이다 — 길어지면 아무도 안 읽고, 짧으면 설명이 안 된다.
    func testExplanationsStayShortEnoughForAPopover() {
        for term in GlossaryTerm.allCases {
            let count = term.explanation.count
            XCTAssertGreaterThan(count, 20, "\(term) 설명이 너무 짧아 설명이 안 된다")
            XCTAssertLessThanOrEqual(count, 120, "\(term) 설명이 팝오버 한 장을 넘긴다")
        }
    }

    func testExplanationsDoNotUseOtherJargon() {
        for term in GlossaryTerm.allCases {
            for banned in bannedInExplanations {
                XCTAssertFalse(
                    term.explanation.contains(banned),
                    "\(term) 설명이 또 다른 용어 '\(banned)'로 도망갔다"
                )
            }
        }
    }

    /// 성부 설명은 "도→미", "도→솔"처럼 계이름으로 실제 거리를 보여준다 — 이론 이름을
    /// 다른 이론 이름으로 바꾸는 대신, 부를 수 있는 소리로 옮기는 게 이 사전의 방식이다.
    ///
    /// 146절에 라벨 자체가 "3도/5도" -> "가운뎃소리/윗소리"(자리 이름)로 바뀌었다. 자리 이름은
    /// 언제나 참이지만 "그래서 무슨 소리인데?"는 답해주지 않는다 — 그 빈칸을 여기서 메운다.
    func testVoiceTermsExplainDistanceWithSolfege() {
        XCTAssertTrue(GlossaryTerm.third.explanation.contains("미"))
        XCTAssertTrue(GlossaryTerm.fifth.explanation.contains("솔"))
    }

    /// 화면에 그대로 뜨는 말들("성부", "조성")은 반드시 사전에 있어야 한다 — 이 둘이
    /// `PracticeView`/`HistoryView`에서 설명 없이 노출되던 게 UI 크리틱 P1의 실제 내용이었다.
    func testTermsExistForWordsShownOnScreen() {
        XCTAssertFalse(GlossaryTerm.voice.explanation.isEmpty)
        XCTAssertFalse(GlossaryTerm.key.explanation.isEmpty)
    }
}
