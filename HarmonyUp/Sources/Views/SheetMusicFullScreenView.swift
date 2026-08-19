import SwiftUI

/// "악보만 보이는 뷰" — VexFlow 렌더링이 실제로 잘 되는지(리듬/쉼표/빔/성부 정렬) 확인하려고
/// 만들었다. `PracticeView`의 "악보" 카드는 고정 높이(`VexFlowScoreView.preferredHeight`)
/// 안에 다른 카드들(녹음/재생/채점)과 나란히 있어서 눈으로 판단하기 좁았다 — 이 화면은 오선보
/// 하나만 화면 전체를 차지하게 해서, 같은 데이터를 훨씬 크게 볼 수 있게 한다.
///
/// `mutedVoices`는 `PracticeView`와 같은 `@Binding`을 그대로 받는다 — 여기서 성부를 껐다 켰다
/// 하면 뒤에서 대기 중인 "내 목소리로 화음" 재생에도 그대로 반영된다(공유 상태, 기존 설계 그대로).
struct SheetMusicFullScreenView: View {
    let steps: [MelodyStep]
    @Binding var mutedVoices: Set<PlaybackVoice>
    // "악보" 카드와 같은 감지된 조성 표시(66절 이후 요청) — 여기서도 같은 정보를 보여줘서
    // 전체화면에서도 제대로 불렀는지 확인할 수 있게 한다.
    var detectedKeyName: String?
    @Environment(\.dismiss) private var dismiss
    // 이 화면은 열릴 때마다 새 WKWebView를 만드니(PracticeView와 별개 인스턴스) 항상 true로
    // 시작 — 로딩 표시 원리는 PracticeView.isScoreRendering과 동일(76절 후속).
    @State private var isScoreRendering = true
    // VexFlowScoreView.contentVersion — 여기선 mutedVoices가 바뀔 때만 다시 그리면 된다
    // (steps는 이 화면이 열려 있는 동안 고정값). 자세한 이유는 PracticeView.scoreContentVersion 참고.
    @State private var scoreContentVersion = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                voiceToggleRow
                    .padding(.horizontal)
                    .padding(.top, Theme.Spacing.sm)

                if let detectedKeyName {
                    Text("감지된 조성: \(detectedKeyName)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.top, Theme.Spacing.xs)
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
                // 탭-재생은 여기서는 아직 다루지 않는다(한 번에 하나씩 순서대로 만드는 이
                // 프로젝트의 방식 그대로, 74절) — 다음 단계에서 이어붙인다.
                ZStack {
                    VexFlowScoreView(steps: steps, mutedVoices: $mutedVoices, activeStepIndex: nil, onSeekToStep: { _ in }, isRendering: $isScoreRendering, contentVersion: scoreContentVersion)
                    if isScoreRendering {
                        PulsingLoadingLabel(message: "악보를 만드는 중이에요")
                    }
                }
            }
            // 흰 배경은 VexFlowScoreView 내부(WKWebView)에만 있다 — 오선지는 다크모드와
            // 무관하게 항상 흰 종이인 게 악보 관례라 의도적으로 그대로 둔다(68절). 하지만 이
            // VStack 전체(토글 행, 조성/음 캡션 텍스트가 있는 크롬)까지 흰 배경이었던 건 그
            // 의도를 벗어난 실수였다 — 다크모드에서 화면 전체가 새하얗게 튀는 버그였다(크리틱
            // P1). 크롬은 다른 화면들과 같은 시스템 배경을 쓰고, 오선지의 흰 종이만 그 안에서
            // 도드라지게 남긴다.
            .background(Color(uiColor: .systemGroupedBackground))
            .onChange(of: mutedVoices) { _, _ in
                scoreContentVersion += 1
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }

    private var voiceToggleRow: some View {
        ViewThatFits {
            HStack {
                ForEach(PlaybackVoice.allCases, id: \.self) { voice in
                    VoiceToggleChip(voice: voice, mutedVoices: $mutedVoices)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(PlaybackVoice.allCases, id: \.self) { voice in
                    VoiceToggleChip(voice: voice, mutedVoices: $mutedVoices)
                }
            }
        }
    }
}
