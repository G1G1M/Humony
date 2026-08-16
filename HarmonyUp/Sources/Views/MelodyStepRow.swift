import SwiftUI

/// 마지막으로 확정된 한 음과, 그 시점 조성 기준으로 만든 화음 — 멜로디 모드에서
/// 부른 음마다 하나씩 쌓아서 "곡 전체를 부르면 순서대로 화음이 나오는" 흐름을 보여준다.
struct MelodyStep: Identifiable {
    let id = UUID()
    var noteName: String
    var midiNote: Int      // 옥타브까지 포함한 실제 MIDI 노트 — 수정 시 같은 옥타브 안에서 pitch class만 바꾸는 데 쓴다.
    var harmonyNames: String?
    // 빠른 녹음(RecordingAnalyzer) 경로에서만 채워진다 — 녹음 시작 기준 시작 시각/길이(초).
    // 실시간 캡처 경로(기존 멜로디 모드)는 "지금 막 확정된 음"이라는 개념만 있고 녹음 타임라인이
    // 없어서 nil로 둔다. 옵셔널로 추가해서 기존 실시간 캡처 코드는 손대지 않고 그대로 컴파일된다.
    var onsetTime: Double? = nil
    var duration: Double? = nil
}

/// 멜로디 모드에서 잡힌 음 한 줄 — 실시간 검출이 틀렸을 때 눌러서 고치는 메뉴와,
/// 이 스텝을 바로 채점 대상으로 고를 수 있는 3도/5도 버튼을 함께 보여준다.
struct MelodyStepRow: View {
    let step: MelodyStep
    let onCorrect: (Int) -> Void
    let onScoreThird: () -> Void
    let onScoreFifth: () -> Void

    var body: some View {
        HStack {
            Menu {
                ForEach(0..<12, id: \.self) { pitchClass in
                    Button(NoteNameConverter.pitchClassName(pitchClass)) {
                        onCorrect(pitchClass)
                    }
                }
            } label: {
                Text("\(step.noteName) ✏️")
                    .font(.system(.body, design: .monospaced))
            }
            Text("→ \(step.harmonyNames ?? "온음계 밖")")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            // 예전엔 채점이 항상 "마지막으로 잡은 음"만 대상으로 해서
            // 멜로디가 여러 개 쌓여도 마지막 스텝만 채점할 수 있었다.
            // 이 스텝의 화음을 그 자리에서 바로 채점 대상으로 고를 수 있게 한다.
            if step.harmonyNames != nil {
                Spacer()
                Button("3도", action: onScoreThird)
                Button("5도", action: onScoreFifth)
            }
        }
        .font(Theme.Typography.caption2)
        .buttonStyle(.bordered)
    }
}
