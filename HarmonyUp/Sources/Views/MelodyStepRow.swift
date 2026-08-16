import SwiftUI

/// 확정된 멜로디 음 하나와, 그 음 위에 쌓은 3성부(베이스/3도/5도) — 빠른 녹음으로 부른
/// 멜로디 전체를 순서대로 쌓아서 "곡 전체를 부르면 음마다 화음이 나오는" 흐름을 보여준다.
struct MelodyStep: Identifiable {
    let id = UUID()
    var noteName: String
    var midiNote: Int      // 옥타브까지 포함한 실제 MIDI 노트 — 수정 시 같은 옥타브 안에서 pitch class만 바꾸는 데 쓴다.
    // 성부(Interval)별 음이름 — 온음계 밖 음이면 nil(화음을 정의할 수 없음). 화면 표시 전용.
    var harmonyVoices: [ChordGenerator.Interval: String]?
    // harmonyVoices의 원본 데이터(실제 주파수 포함) — 채점/재생이 이 값을 그대로 읽어 쓴다.
    // Viterbi 기반 화음(ChordGenerator.harmonizeSequence)은 문맥(앞뒤 노트)을 보고 코드를
    // 고르므로, 스텝 하나만 떼어 다시 계산할 수 없다 — 배치로 한 번에 계산한 결과를 그대로
    // 들고 있어야 한다(docs/CONCEPTS.md 51절).
    var harmony: [ChordGenerator.HarmonyNote]? = nil
    // 빠른 녹음(RecordingAnalyzer) 경로에서만 채워진다 — 녹음 시작 기준 시작 시각/길이(초).
    var onsetTime: Double? = nil
    var duration: Double? = nil
}

extension MelodyStep {
    /// `ChordGenerator.HarmonyNote` 배열(베이스/3도/5도)을 이 화면이 그대로 쓸 수 있는
    /// [성부: 음이름] 딕셔너리로 변환한다 — `RecordingAnalyzer`/`PracticeView` 양쪽에서 같은
    /// 변환을 반복하지 않도록 한 곳에 모았다.
    static func harmonyVoices(from harmony: [ChordGenerator.HarmonyNote]?) -> [ChordGenerator.Interval: String]? {
        guard let harmony else { return nil }
        return Dictionary(uniqueKeysWithValues: harmony.map { note in
            (note.interval, NoteNameConverter.convert(frequency: note.frequency)?.noteName ?? "?")
        })
    }
}

/// 멜로디 스텝 한 줄 — 실시간 검출이 틀렸을 때 눌러서 고치는 메뉴와, 이 스텝을 바로 채점
/// 대상으로 고를 수 있는 베이스/3도/5도 버튼을 함께 보여준다.
struct MelodyStepRow: View {
    let step: MelodyStep
    let onCorrect: (Int) -> Void
    let onScoreThird: () -> Void
    let onScoreFifth: () -> Void
    let onScoreBass: () -> Void

    // 성부가 3개로 늘면서(베이스+3도+5도) 한 줄에 다 나열하면 좁아진다 — Interval.allCases
    // 순서(베이스, 3도, 5도)대로 "라벨 음이름" 형태로 이어 붙인다.
    private var harmonySummary: String {
        guard let voices = step.harmonyVoices else { return "온음계 밖" }
        return ChordGenerator.Interval.allCases
            .compactMap { interval in voices[interval].map { "\(interval.koreanLabel) \($0)" } }
            .joined(separator: ", ")
    }

    private var noteMenu: some View {
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
    }

    private var harmonyText: some View {
        Text("→ \(harmonySummary)")
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    // 예전엔 채점이 항상 "마지막으로 잡은 음"만 대상으로 해서 멜로디가 여러 개 쌓여도
    // 마지막 스텝만 채점할 수 있었다 — 이 스텝의 화음을 그 자리에서 바로 채점 대상으로 고를 수 있게 한다.
    @ViewBuilder
    private var scoreButtons: some View {
        if step.harmonyVoices != nil {
            HStack {
                Button(ChordGenerator.Interval.bass.koreanLabel, action: onScoreBass)
                Button(ChordGenerator.Interval.third.koreanLabel, action: onScoreThird)
                Button(ChordGenerator.Interval.fifth.koreanLabel, action: onScoreFifth)
            }
        }
    }

    var body: some View {
        // 음이름+화음 요약+버튼 3개가 한 줄에 안 들어갈 만큼 글자가 커지면(Dynamic Type)
        // 자동으로 세로 배치(요약 줄 아래에 버튼 줄)로 전환된다.
        ViewThatFits {
            HStack {
                noteMenu
                harmonyText
                Spacer()
                scoreButtons
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    noteMenu
                    harmonyText
                }
                scoreButtons
            }
        }
        .font(Theme.Typography.caption2)
        .buttonStyle(.bordered)
    }
}
