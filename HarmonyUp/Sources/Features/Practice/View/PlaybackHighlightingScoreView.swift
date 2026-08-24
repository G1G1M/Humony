import SwiftUI

/// 악보를 그리면서 **재생 위치를 따라 강조**하는 뷰(149절).
///
/// **왜 `PracticeView`가 아니라 별도 뷰인가**: 하이라이트 상태를 `PracticeView`의 `@State`로 두면
/// 음이 바뀔 때마다 그 큰 화면(녹음 조작부·성부 4행·채점 카드·악보)의 `body`가 통째로 다시
/// 평가된다. 재생 중에 그 비용이 오디오와 CPU를 다투는 건 이 프로젝트가 이미 겪은 패턴이다 —
/// `render.js`에 "악보 넘어가면서 소리가 날 때 렉이 걸린다"는 제보와 그 대응(스크롤 재트리거
/// 임계값)이 기록돼 있고, 84절도 같은 계열이다. 상태를 이 작은 뷰 안에 가두면 음이 바뀔 때
/// 다시 평가되는 건 악보 서브트리뿐이다.
///
/// 타임라인도 여기서 한 번만 만들어 들고 있는다 — 매 틱마다 `ScoreTimeline.events`를 다시
/// 계산하면 초당 수십 번 배열을 새로 할당하게 된다.
struct PlaybackHighlightingScoreView: View {

    let steps: [MelodyStep]
    let contentVersion: Int
    @Binding var isRendering: Bool
    /// 지금 재생 위치(초). 재생 중이 아니면 nil을 돌려준다.
    let currentPlaybackTime: () -> TimeInterval?

    @State private var events: [ScoreTimeline.Event] = []
    @State private var activeIndex: Int?

    /// 10Hz. 음표 하나가 보통 0.3~1.2초라 이보다 촘촘히 볼 이유가 없고, 틱을 줄이는 만큼
    /// 재생 중 메인 스레드가 깨는 횟수도 줄어든다.
    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VexFlowScoreView(
            steps: steps,
            activeStepIndex: activeIndex,
            onSeekToStep: { _ in },
            isRendering: $isRendering,
            contentVersion: contentVersion
        )
        .onAppear { rebuildTimeline() }
        .onChange(of: contentVersion) { rebuildTimeline() }
        .onReceive(ticker) { _ in updateHighlight() }
    }

    private func rebuildTimeline() {
        events = ScoreTimeline.events(from: steps)
        activeIndex = nil
    }

    /// 재생 중이 아니면 nil을 보낸다 — `render.js`가 그때 하이라이트를 지우고 악보를 처음으로
    /// 되감는다. 쉼표 구간에서는 `highlightIndex`가 직전 음표를 유지하므로 여기로 nil이 오지
    /// 않는다(안 그러면 노래 중간에 악보가 맨 앞으로 튕긴다).
    private func updateHighlight() {
        guard let time = currentPlaybackTime() else {
            if activeIndex != nil { activeIndex = nil }
            return
        }
        let index = ScoreTimeline.highlightIndex(at: time, events: events)
        // 값이 실제로 바뀔 때만 상태를 쓴다 — 같은 값을 다시 대입하면 초당 10번씩 이 서브트리가
        // 불필요하게 다시 평가된다.
        if activeIndex != index { activeIndex = index }
    }
}
