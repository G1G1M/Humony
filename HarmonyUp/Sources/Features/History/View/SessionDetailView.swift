import SwiftUI
import SwiftData

/// 기록 하나(녹음 세션)의 상세 — **그때 부른 악보를 다시 보고**, 그 위에서 성부별 채점 결과를
/// 확인한다(136절).
///
/// 오디오는 저장하지 않으므로 다시 들을 수는 없지만, 음높이와 길이는 `PracticeSession`에
/// 남아 있어서 `melodySteps()`로 되돌리면 기존 `VexFlowScoreView`가 그때의 4성부 악보를 그대로
/// 그려준다 — 화면을 새로 만들지 않고 재사용한다.
struct SessionDetailView: View {
    let session: PracticeSession

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var isScoreRendering = true
    @State private var showingDeleteConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HarmonyCard("그때 부른 악보", systemImage: "pianokeys") {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("\(session.keyName) · 음 \(session.noteCount)개")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)

                        ZStack {
                            VexFlowScoreView(
                                steps: session.melodySteps(),
                                activeStepIndex: nil,
                                onSeekToStep: { _ in },
                                isRendering: $isScoreRendering,
                                contentVersion: 0
                            )
                            .frame(height: VexFlowScoreView.preferredHeight)

                            if isScoreRendering {
                                PulsingLoadingLabel(message: "악보를 만드는 중이에요")
                            }
                        }
                    }
                }

                if sortedAttempts.isEmpty {
                    HarmonyCard("채점", systemImage: "target") {
                        Text("이 녹음에서는 채점을 하지 않았어요")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(sortedAttempts.enumerated()), id: \.element.persistentModelID) { _, attempt in
                        attemptCard(attempt, round: roundNumber(of: attempt))
                    }
                }

                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("이 기록 삭제", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .harmonyButtonStyle()
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(session.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("이 기록을 지울까요?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("지우기", role: .destructive) {
                modelContext.delete(session)
                try? modelContext.save()
                dismiss()
            }
            Button("취소", role: .cancel) {}
        }
    }

    /// 성부 순서를 화면마다 뒤바뀌지 않게 고정한다 — 악보와 같은 음높이 내림차순
    /// (`ChordGenerator.Interval.displayOrder`).
    private var sortedAttempts: [PracticeAttempt] {
        session.attempts.sorted { lhs, rhs in
            let lhsIndex = lhs.interval?.displayIndex ?? ChordGenerator.Interval.displayOrder.count
            let rhsIndex = rhs.interval?.displayIndex ?? ChordGenerator.Interval.displayOrder.count
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.date < rhs.date
        }
    }

    /// 같은 성부를 여러 번 불렀을 때 이게 몇 번째 시도인지(1부터). 한 번뿐이면 nil —
    /// 굳이 "1회차"라고 붙이면 오히려 시끄럽다.
    private func roundNumber(of attempt: PracticeAttempt) -> Int? {
        let sameVoice = session.attempts
            .filter { $0.intervalRawValue == attempt.intervalRawValue }
            .sorted { $0.date < $1.date }
        guard sameVoice.count > 1,
              let index = sameVoice.firstIndex(where: { $0.persistentModelID == attempt.persistentModelID })
        else { return nil }
        return index + 1
    }

    private func attemptCard(_ attempt: PracticeAttempt, round: Int?) -> some View {
        let interval = attempt.interval
        let color = interval.map { Theme.intervalColor(for: $0) } ?? .secondary
        // 같은 성부를 다시 불렀으면 카드 제목이 똑같이 여러 개 뜬다 — 몇 번째 시도인지 붙여서
        // 구분한다("3도 따라 부르기 · 2회차").
        let title = round.map { "\(interval?.koreanLabel ?? "?") 따라 부르기 · \($0)회차" }
            ?? "\(interval?.koreanLabel ?? "?") 따라 부르기"

        return HarmonyCard(title, systemImage: "target") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                    Text(String(format: "%.0f%%", attempt.onPitchRatio * 100))
                        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                        .foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("목표 \(attempt.targetNoteCount)음 중 정확히 부른 비율")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "평균 ±%.0fcent", attempt.averageAbsCentsOffset))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if attempt.missedCount > 0 || attempt.extraCount > 0 {
                    Text(missedExtraSummary(attempt))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.warning)
                }

                // 벗어난 음의 정체 — "어디서 틀리는지"에 답하는 부분이라 정확도 숫자보다
                // 실제로 더 쓸모가 있다.
                if !attempt.offTargetMIDINotes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("벗어난 음")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(offTargetSummary(attempt))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                if !attempt.missedMIDINotes.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("안 부른 음")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(attempt.missedMIDINotes.map(noteName).joined(separator: " · "))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func missedExtraSummary(_ attempt: PracticeAttempt) -> String {
        var parts: [String] = []
        if attempt.missedCount > 0 { parts.append("안 부른 음 \(attempt.missedCount)개") }
        if attempt.extraCount > 0 { parts.append("목표에 없는 음 \(attempt.extraCount)개") }
        return parts.joined(separator: " · ")
    }

    /// "F3 −38 · A3 +42" 형태 — 부호를 살려서 낮게/높게를 그대로 읽을 수 있게 한다.
    private func offTargetSummary(_ attempt: PracticeAttempt) -> String {
        zip(attempt.offTargetMIDINotes, attempt.offTargetCents)
            .map { midiNote, cents in String(format: "%@ %+.0f", noteName(midiNote), cents) }
            .joined(separator: " · ")
    }

    private func noteName(_ midiNote: Int) -> String {
        NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?"
    }
}
