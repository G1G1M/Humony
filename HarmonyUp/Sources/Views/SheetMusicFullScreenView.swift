import SwiftUI

/// "악보만 보이는 뷰" — VexFlow 렌더링이 실제로 잘 되는지(리듬/쉼표/빔 정렬) 확인하려고
/// 만들었다. `PracticeView`의 "악보" 카드는 고정 높이(`VexFlowScoreView.preferredHeight`)
/// 안에 다른 카드들과 나란히 있어서 눈으로 판단하기 좁았다 — 이 화면은 오선보 하나만 화면
/// 전체를 차지하게 해서, 같은 데이터를 훨씬 크게 볼 수 있게 한다.
///
/// **2026-08-24(136절)**: `VexFlowScoreView`가 다시 4성부(멜로디/5도/3도/베이스)를 그리게
/// 되면서 이 화면도 같은 뷰를 쓰는 덕에 자동으로 4행이 된다 — 좁은 카드에서 4행을 보기가
/// 특히 답답하므로 이 전체화면의 쓸모가 오히려 커졌다. 성부 뮤트 토글은 116절에 없앤 채다.
struct SheetMusicFullScreenView: View {
    let steps: [MelodyStep]
    // "악보" 카드와 같은 감지된 조성 표시(66절 이후 요청) — 여기서도 같은 정보를 보여줘서
    // 전체화면에서도 제대로 불렀는지 확인할 수 있게 한다.
    var detectedKeyName: String?
    @Environment(\.dismiss) private var dismiss
    // 이 화면은 열릴 때마다 새 WKWebView를 만드니(PracticeView와 별개 인스턴스) 항상 true로
    // 시작 — 로딩 표시 원리는 PracticeView.isScoreRendering과 동일(76절 후속).
    @State private var isScoreRendering = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let detectedKeyName {
                    Text("감지된 조성: \(detectedKeyName)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, Theme.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !steps.isEmpty {
                    Text("감지된 음: " + steps.map(\.noteName).joined(separator: " · "))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, Theme.Spacing.xs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 프레임을 따로 안 주면 NavigationStack의 남은 세로 공간을 그대로 받는다 —
                // score.html 내부가 이미 overflow:auto라, 여기서 넘치는 내용은 웹뷰 안에서
                // 스크롤된다(바깥에 SwiftUI ScrollView를 또 두면 스크롤이 중첩돼 오히려 헷갈림).
                ZStack {
                    VexFlowScoreView(steps: steps, activeStepIndex: nil, onSeekToStep: { _ in }, isRendering: $isScoreRendering, contentVersion: 0)
                    if isScoreRendering {
                        PulsingLoadingLabel(message: "악보를 만드는 중이에요")
                    }
                }
            }
            // 흰 배경은 VexFlowScoreView 내부(WKWebView)에만 있다 — 오선지는 다크모드와
            // 무관하게 항상 흰 종이인 게 악보 관례라 의도적으로 그대로 둔다(68절). 크롬은
            // 다른 화면들과 같은 시스템 배경을 쓰고, 오선지의 흰 종이만 그 안에서 도드라지게 남긴다.
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}
