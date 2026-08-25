import SwiftUI

/// 앱의 새 루트 화면 — 탭 2개(연습/기록)로 나눈다. 캡처~채점까지 한 세션의 흐름(연습)과,
/// 캡처 상태와 무관하게 열람하는 과거 기록(기록)은 서로 다른 사용 맥락이라 탭으로 분리했다.
///
/// 최초 실행이면 여기서 온보딩(`OnboardingView`)을 덮어 띄운다. 루트가 이 판단을 맡는 이유는
/// 온보딩이 특정 탭의 사정이 아니라 앱 전체의 첫 관문이기 때문이다.
struct RootTabView: View {
    /// 뷰가 만들어질 때 한 번만 판단한다 — 온보딩을 끝내고 `markCompleted`를 부른 뒤
    /// 이 값을 다시 읽으면, 사용자가 방금 지나온 화면이 그대로 다시 뜬다.
    @State private var showsOnboarding = OnboardingGate.shouldPresent()

    var body: some View {
        TabView {
            PracticeView()
                .tabItem {
                    Label("연습", systemImage: "mic.fill")
                }

            HistoryView()
                .tabItem {
                    Label("기록", systemImage: "clock.arrow.circlepath")
                }
        }
        .tint(Theme.tint)
        // 전체 화면으로 덮는 이유: 탭 바가 보이는 채로 온보딩을 띄우면 "지금 이걸 봐야 하는지,
        // 그냥 탭을 눌러도 되는지"가 애매해진다. 첫 관문은 하나의 길만 보여주는 게 낫다.
        .fullScreenCover(isPresented: $showsOnboarding) {
            OnboardingView {
                OnboardingGate.markCompleted()
                showsOnboarding = false
            }
        }
    }
}
