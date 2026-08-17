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
                VexFlowScoreView(steps: steps, mutedVoices: $mutedVoices)
            }
            .background(Color.white)
            .navigationTitle("악보")
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
                    voiceToggle(voice)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(PlaybackVoice.allCases, id: \.self) { voice in
                    voiceToggle(voice)
                }
            }
        }
    }

    private func voiceToggle(_ voice: PlaybackVoice) -> some View {
        let isMuted = mutedVoices.contains(voice)
        return Button {
            if isMuted {
                mutedVoices.remove(voice)
            } else {
                mutedVoices.insert(voice)
            }
        } label: {
            Label(voice.koreanLabel, systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .harmonyButtonStyle()
        .tint(isMuted ? .secondary : Theme.tint)
    }
}
