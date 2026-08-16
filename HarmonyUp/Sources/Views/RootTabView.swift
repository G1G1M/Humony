import SwiftUI

/// 앱의 새 루트 화면 — 탭 2개(연습/기록)로 나눈다. 캡처~채점까지 한 세션의 흐름(연습)과,
/// 캡처 상태와 무관하게 열람하는 과거 기록(기록)은 서로 다른 사용 맥락이라 탭으로 분리했다.
struct RootTabView: View {
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
    }
}
