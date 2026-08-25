import Foundation

/// "온보딩을 지금 띄워야 하는가"를 판단하는 한 곳.
///
/// 이 앱은 이번 작업 전까지 `UserDefaults`/`@AppStorage`를 한 곳도 쓰지 않았다 — 즉 "최초
/// 실행인가"를 알 방법 자체가 없었다. 그 판단을 뷰에 `@AppStorage`로 흩뿌리지 않고 여기
/// 모으는 이유는, 뷰에 박힌 `@AppStorage`는 앱 전역 저장소를 그대로 건드려서 테스트에서
/// 격리할 수 없고, 키 문자열이 두 곳에 복사되면 한쪽만 고쳤을 때 **온보딩이 매번 다시 뜨거나
/// 영영 안 뜨는** 조용한 버그가 되기 때문이다.
enum OnboardingGate {
    /// 키에 버전을 달아 둔다 — 나중에 온보딩을 개편했을 때 "기존 사용자에게 새 온보딩을 다시
    /// 보여줄지"를 이 숫자 하나로 정할 수 있다.
    static let completionKey = "onboarding.completed.v1"

    static func shouldPresent(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: completionKey)
    }

    /// **"나중에 할게요"로 빠져나가도 완료로 친다.** 온보딩을 볼지 말지는 사용자가 정하는
    /// 것이고, 켤 때마다 같은 3장을 다시 들이미는 앱이 되면 안 된다. 마이크 권한은 어차피
    /// 녹음 버튼을 누를 때 기존 흐름(`beginCapturingIfNeeded`)이 다시 물어본다.
    static func markCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: completionKey)
    }
}
