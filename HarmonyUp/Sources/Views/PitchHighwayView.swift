import SwiftUI

/// 녹음한 멜로디 전체를 "피치 하이웨이"(시간=가로축, 음높이=세로축인 피아노롤과 비슷한 방식)로
/// 한눈에 보여준다. 정통 5선보 대신 이 방식을 고른 이유 — 이 앱은 애초에 "3도/5도" 같은 최소한의
/// 용어만 쓰고 화성학을 몰라도 되게 설계돼 있는데, 5선보는 악보를 읽을 줄 알아야 해서 그 원칙과
/// 어긋난다. Yousician/Simply Piano 같은 보컬·악기 연습 앱들이 실제로 이 방식을 쓴다
/// (docs/CONCEPTS.md 55절 리서치 참고). 멜로디(리드)와 그 위에 쌓은 베이스/3도/5도를 색으로
/// 구분해서 같은 시간축 위에 겹쳐 그린다.
struct PitchHighwayView: View {
    let steps: [MelodyStep]

    private let pixelsPerSecond: CGFloat = 70
    private let pixelsPerSemitone: CGFloat = 10
    private let barHeight: CGFloat = 16
    private let leadingLabelWidth: CGFloat = 36

    private let melodyColor = Theme.tint

    private func color(for interval: ChordGenerator.Interval) -> Color {
        switch interval {
        case .bass: return Color(uiColor: .systemGray)
        case .third: return Color(uiColor: .systemTeal)
        case .fifth: return Theme.voiceAccent
        }
    }

    // 멜로디 음뿐 아니라 그 위에 쌓인 베이스/3도/5도까지 전부 포함해서 세로축 범위를 잡아야
    // 화면 밖으로 잘리는 성부가 없다.
    private var pitchRange: ClosedRange<Int> {
        var notes = steps.map(\.midiNote)
        for step in steps {
            if let harmony = step.harmony {
                notes.append(contentsOf: harmony.map(\.midiNote))
            }
        }
        guard let lo = notes.min(), let hi = notes.max() else { return 60...72 }
        return (lo - 1)...(hi + 1)
    }

    private var totalDuration: Double {
        steps.compactMap { step -> Double? in
            guard let onset = step.onsetTime, let duration = step.duration else { return nil }
            return onset + duration
        }.max() ?? 1
    }

    private var octaveMarks: [Int] {
        let range = pitchRange
        return stride(from: 0, through: 127, by: 12).filter { range.contains($0) }
    }

    private func x(_ time: Double) -> CGFloat { CGFloat(time) * pixelsPerSecond }

    private func y(_ midiNote: Int, range: ClosedRange<Int>) -> CGFloat {
        CGFloat(range.upperBound - midiNote) * pixelsPerSemitone
    }

    private func noteName(_ midiNote: Int) -> String {
        NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?"
    }

    var body: some View {
        let range = pitchRange
        let contentHeight = CGFloat(range.upperBound - range.lowerBound) * pixelsPerSemitone + barHeight
        let contentWidth = x(totalDuration) + 24

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            legend

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    octaveGridlines(range: range, width: contentWidth)
                    ForEach(steps) { step in
                        stepBars(step, range: range)
                    }
                }
                .frame(width: contentWidth + leadingLabelWidth, height: contentHeight, alignment: .topLeading)
            }
            .frame(maxHeight: 260)
            .background(
                Color(uiColor: .tertiarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }

    private var legend: some View {
        HStack(spacing: Theme.Spacing.md) {
            legendItem(label: "멜로디", color: melodyColor)
            ForEach(ChordGenerator.Interval.allCases, id: \.self) { interval in
                legendItem(label: interval.koreanLabel, color: color(for: interval))
            }
        }
    }

    private func legendItem(label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(Theme.Typography.caption2).foregroundStyle(.secondary)
        }
    }

    // 옥타브(C음)마다 가로 기준선 + 음이름을 왼쪽에 붙여서, 막대만 있을 때보다 "지금 이 높이가
    // 대략 어떤 음인지" 감이 오게 한다.
    @ViewBuilder
    private func octaveGridlines(range: ClosedRange<Int>, width: CGFloat) -> some View {
        ForEach(octaveMarks, id: \.self) { midiNote in
            HStack(spacing: 4) {
                Text(noteName(midiNote))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: leadingLabelWidth - 4, alignment: .trailing)
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(width: width, height: 1)
            }
            .offset(x: 0, y: y(midiNote, range: range) + barHeight / 2)
        }
    }

    @ViewBuilder
    private func stepBars(_ step: MelodyStep, range: ClosedRange<Int>) -> some View {
        if let onset = step.onsetTime, let duration = step.duration {
            let barWidth = max(x(duration), 6)
            let barX = x(onset) + leadingLabelWidth

            if let harmony = step.harmony {
                ForEach(harmony, id: \.interval) { note in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(for: note.interval).opacity(0.85))
                        .frame(width: barWidth, height: barHeight)
                        .position(x: barX + barWidth / 2, y: y(note.midiNote, range: range) + barHeight / 2)
                }
            }

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(melodyColor)
                .frame(width: barWidth, height: barHeight)
                .position(x: barX + barWidth / 2, y: y(step.midiNote, range: range) + barHeight / 2)
        }
    }
}
