import XCTest
@testable import Humony

/// "온보딩을 지금 띄워야 하는가"를 판단하는 순수 로직을 고정한다.
///
/// 이 앱은 이번 작업 전까지 `UserDefaults`/`@AppStorage`를 **한 곳도** 쓰지 않았다 — 즉
/// "최초 실행인가"를 알 방법 자체가 없었다. 그 판단을 뷰에 `@AppStorage`로 흩뿌리는 대신
/// 여기 한 곳에 모으는 이유는 두 가지다.
///
/// 1. 뷰에 박힌 `@AppStorage`는 테스트에서 격리할 수 없다(앱 전역 저장소를 그대로 건드린다).
///    `UserDefaults`를 주입받는 순수 타입으로 두면 테스트마다 깨끗한 저장소를 쓸 수 있다.
/// 2. 키 문자열이 두 곳에 복사되면 한쪽만 고쳤을 때 **온보딩이 매번 다시 뜨거나 영영 안 뜨는**
///    조용한 버그가 된다.
final class OnboardingGateTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // 앱 전역 저장소를 오염시키지 않도록 테스트마다 별도 스위트를 쓴다.
        suiteName = "OnboardingGateTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testPresentsOnFirstLaunch() {
        XCTAssertTrue(OnboardingGate.shouldPresent(in: defaults))
    }

    func testDoesNotPresentAfterCompletion() {
        OnboardingGate.markCompleted(in: defaults)
        XCTAssertFalse(OnboardingGate.shouldPresent(in: defaults))
    }

    func testCompletionSurvivesRepeatedMarking() {
        OnboardingGate.markCompleted(in: defaults)
        OnboardingGate.markCompleted(in: defaults)
        XCTAssertFalse(OnboardingGate.shouldPresent(in: defaults))
    }

    /// 키에 버전을 달아두면 나중에 온보딩을 개편했을 때 "기존 사용자에게 새 온보딩을 다시
    /// 보여줄지"를 키 하나 올리는 것으로 정할 수 있다.
    func testCompletionKeyIsVersioned() {
        XCTAssertTrue(OnboardingGate.completionKey.contains("v1"))
    }
}
