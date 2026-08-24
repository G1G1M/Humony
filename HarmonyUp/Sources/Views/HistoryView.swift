import SwiftUI
import SwiftData
import Charts

/// "기록" 탭 — 과거 연습을 **녹음 세션 단위**로 보여준다(136절).
///
/// 예전엔 채점 시도(`PracticeAttempt`)가 평평하게 쌓여서 "3도 82%" 같은 줄의 나열이었다 —
/// 어느 노래를 부르다 나온 점수인지, 같은 녹음에서 성부를 바꿔 여러 번 시도한 것인지 구분할
/// 수 없었다. 이제 녹음 하나가 세션이 되고 그 아래 성부별 시도가 달려서, 탭하면 그때의 악보와
/// 성부별 결과를 다시 볼 수 있다.
///
/// 통계 계산은 `PracticeStatistics`(순수 함수)에 있다 — 이 뷰는 모델에서 값을 꺼내 넘기는
/// 얇은 변환만 한다.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeSession.date, order: .reverse) private var sessions: [PracticeSession]
    @State private var showingClearConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("기록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !sessions.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showingClearConfirmation = true
                        } label: {
                            Label("전체 비우기", systemImage: "trash")
                        }
                    }
                }
            }
            .confirmationDialog(
                "기록을 전부 지울까요?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("전부 지우기", role: .destructive) { deleteAllSessions() }
                Button("취소", role: .cancel) {}
            } message: {
                Text("연습 \(sessions.count)개가 사라져요. 되돌릴 수 없어요.")
            }
        }
        .tint(Theme.tint)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                summaryCard

                if let insights = insightMessages, !insights.isEmpty {
                    HarmonyCard("연습 힌트", systemImage: "lightbulb") {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ForEach(insights, id: \.self) { message in
                                Text(message)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }

                if accuracyPoints.count >= 2 {
                    HarmonyCard("정확도 추이", systemImage: "chart.xyaxis.line") {
                        accuracyTrendChart
                    }
                }

                HarmonyCard("연습 기록", systemImage: "clock") {
                    VStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.persistentModelID) { index, session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                sessionRow(session)
                            }
                            .buttonStyle(.plain)
                            // ScrollView 안이라 List의 스와이프 삭제를 쓸 수 없다 — 카드 기반
                            // 레이아웃(HarmonyCard)을 그대로 유지하려고 길게 눌러 삭제하는
                            // 방식을 쓴다. 발견성이 스와이프보다 낮으니, 세션 상세 화면에도
                            // 눈에 보이는 삭제 버튼을 따로 둔다.
                            .contextMenu {
                                Button("이 기록 삭제", systemImage: "trash", role: .destructive) {
                                    delete(session)
                                }
                            }

                            if index < sessions.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 요약

    private var summaryCard: some View {
        HarmonyCard("한눈에 보기", systemImage: "chart.bar.fill") {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                summaryItem(title: "연속 연습", value: streakDays > 0 ? "\(streakDays)일" : "—")
                summaryItem(title: "연습 횟수", value: "\(sessions.count)회")
                summaryItem(
                    title: "이번 주 정확도",
                    value: weeklyAccuracy.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
        }
    }

    private func sessionRow(_ session: PracticeSession) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.date.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
                    .font(Theme.Typography.subheadlineBold)
                Text("\(session.keyName) · 음 \(session.noteCount)개")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if session.attempts.isEmpty {
                Text("채점 없음")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                // 성부별 정확도를 정체성 색으로 나란히 — 색만으로 구분하지 않게 성부 이름도 같이.
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(sortedAttempts(of: session), id: \.persistentModelID) { attempt in
                        VStack(spacing: 1) {
                            Text(attempt.interval?.koreanLabel ?? "?")
                                .font(Theme.Typography.caption2)
                            Text(String(format: "%.0f%%", attempt.onPitchRatio * 100))
                                .font(.system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(attempt.interval.map { Theme.intervalColor(for: $0) } ?? .secondary)
                    }
                }
            }

            Image(systemName: "chevron.right")
                .font(Theme.Typography.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .contentShape(Rectangle()) // 행 전체가 탭 영역이 되게 한다(빈 공간도 포함)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("아직 기록 없음")
                .font(Theme.Typography.headline)
            Text("연습 탭에서 화음 성부를 따라 부르고 채점을 마치면 여기에 쌓여요")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity)
        // 고정 오프셋(.padding(.top, 80))으로 내리면 화면이 클수록 중앙보다 한참 위에 붙어
        // 보인다 — 스크롤뷰가 보이는 영역과 같은 높이를 줘서 frame의 기본 정렬(.center)이
        // 실제 세로 중앙에 오게 한다.
        .containerRelativeFrame(.vertical)
    }

    // MARK: - 통계 (PracticeStatistics에 위임)

    private var allAttempts: [PracticeAttempt] {
        sessions.flatMap(\.attempts)
    }

    /// 성부 순서를 화면마다 뒤바뀌지 않게 고정한다 — 악보와 같은 음높이 내림차순
    /// (`ChordGenerator.Interval.displayOrder`).
    private func sortedAttempts(of session: PracticeSession) -> [PracticeAttempt] {
        session.attempts.sorted { lhs, rhs in
            let lhsIndex = lhs.interval?.displayIndex ?? ChordGenerator.Interval.displayOrder.count
            let rhsIndex = rhs.interval?.displayIndex ?? ChordGenerator.Interval.displayOrder.count
            if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
            return lhs.date < rhs.date
        }
    }

    private var streakDays: Int {
        PracticeStatistics.streakDays(sessionDates: sessions.map(\.date), today: Date())
    }

    /// 최근 7일 안의 채점 시도 평균 정확도 — 없으면 nil("—"로 표시).
    private var weeklyAccuracy: Double? {
        guard let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) else { return nil }
        let recent = allAttempts.filter { $0.date >= weekAgo }
        guard !recent.isEmpty else { return nil }
        return recent.map(\.onPitchRatio).reduce(0, +) / Double(recent.count)
    }

    /// 다음에 무엇을 연습할지 알려주는 짧은 문장들 — 성부 단위(어느 성부가 약한지), 음 단위
    /// (어느 음에서 반복해 틀리는지), 방향(높게/낮게 부르는 편)의 세 층으로 본다.
    private var insightMessages: [String]? {
        guard !allAttempts.isEmpty else { return nil }
        var messages: [String] = []

        if let weakest = weakestIntervalMessage {
            messages.append(weakest)
        }

        let offTargets = PracticeStatistics.frequentOffTargets(
            allAttempts.flatMap { attempt in
                zip(attempt.offTargetMIDINotes, attempt.offTargetCents).map { (midiNote: $0, cents: $1) }
            }
        )
        for note in offTargets {
            let direction = note.averageCents > 0 ? "높게" : "낮게"
            messages.append(String(
                format: "%@에서 자주 %@ 불러요 — 평균 %.0fcent (%d회)",
                note.noteName, direction, abs(note.averageCents), note.occurrences
            ))
        }

        switch PracticeStatistics.bias(signedOffsets: allAttempts.map(\.averageSignedCentsOffset)) {
        case .sharp(let cents):
            messages.append(String(format: "전반적으로 %.0fcent 높게 부르는 편이에요", cents))
        case .flat(let cents):
            messages.append(String(format: "전반적으로 %.0fcent 낮게 부르는 편이에요", cents))
        case .balanced:
            break
        }

        return messages
    }

    /// 성부별 평균 정확도 차이가 뚜렷하면(10%p 이상) 어느 성부가 약한지 알려준다 — PRD
    /// 페르소나 시나리오의 "5도 화음에서 정확도가 낮음을 확인"에 해당한다. 기록이 없는 성부는
    /// 비교 대상에서 자연히 빠진다.
    private var weakestIntervalMessage: String? {
        let averages = ChordGenerator.Interval.displayOrder.compactMap { interval -> (ChordGenerator.Interval, Double)? in
            let list = allAttempts.filter { $0.intervalRawValue == interval.storageKey }
            guard !list.isEmpty else { return nil }
            return (interval, list.map(\.onPitchRatio).reduce(0, +) / Double(list.count))
        }
        guard averages.count >= 2,
              let weakest = averages.min(by: { $0.1 < $1.1 }),
              let strongest = averages.max(by: { $0.1 < $1.1 }),
              strongest.1 - weakest.1 > 0.1 else { return nil }
        return "\(weakest.0.koreanLabel) 화음에서 더 자주 벗어나는 편이에요"
    }

    // MARK: - 정확도 추이 차트

    private struct AccuracyPoint: Identifiable {
        let id = UUID()
        let date: Date
        let interval: ChordGenerator.Interval
        let onPitchPercent: Double
    }

    /// 시간순(오래된 것 -> 최근)으로 정렬 — `sessions`는 목록용으로 최신순이지만, LineMark는
    /// 주어진 순서 그대로 이어 그리므로 차트에서는 오름차순이어야 선이 왼쪽에서 오른쪽으로 간다.
    private var accuracyPoints: [AccuracyPoint] {
        allAttempts
            .sorted { $0.date < $1.date }
            .compactMap { attempt in
                guard let interval = attempt.interval else { return nil }
                return AccuracyPoint(date: attempt.date, interval: interval, onPitchPercent: attempt.onPitchRatio * 100)
            }
    }

    /// 여러 시도에 걸친 변화를 한 그림으로 압축해서 보여준다. 성부 3개를 색만으로 구분하지 않고
    /// 심볼 모양도 다르게 줘서(범례+symbol 이중 인코딩) 색맹이어도 구분 가능하게 했다.
    private var accuracyTrendChart: some View {
        Chart(accuracyPoints) { point in
            LineMark(
                x: .value("날짜", point.date),
                y: .value("정확도", point.onPitchPercent)
            )
            .foregroundStyle(by: .value("성부", point.interval.koreanLabel))
            .symbol(by: .value("성부", point.interval.koreanLabel))
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .chartForegroundStyleScale([
            ChordGenerator.Interval.bass.koreanLabel: Theme.intervalColor(for: .bass),
            ChordGenerator.Interval.third.koreanLabel: Theme.intervalColor(for: .third),
            ChordGenerator.Interval.fifth.koreanLabel: Theme.intervalColor(for: .fifth),
        ])
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text("\(Int(percent))%")
                    }
                }
            }
        }
        .frame(height: 180)
        .accessibilityLabel("성부별 정확도 추이 그래프, 연습 기록 목록과 같은 데이터를 그래프로 보여줍니다")
    }

    // MARK: - 삭제

    private func delete(_ session: PracticeSession) {
        // attempts는 cascade 삭제 규칙(PracticeSession.attempts)이라 같이 지워진다.
        modelContext.delete(session)
        try? modelContext.save()
    }

    private func deleteAllSessions() {
        for session in sessions {
            modelContext.delete(session)
        }
        try? modelContext.save()
    }
}
