import SwiftUI
import SwiftData

/// "기록" 탭 — 과거 채점 시도(PracticeAttempt)를 모아 보여준다. 캡처 상태와 무관하게 독립적으로
/// 열람하는 화면이라 연습 화면과 분리했다(둘을 한 화면에 이어 붙이면 기록을 보려고 매번
/// 연습용 UI를 스크롤해서 지나쳐야 했다).
struct HistoryView: View {
    @Query(sort: \PracticeAttempt.date, order: .reverse) private var attempts: [PracticeAttempt]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    if attempts.isEmpty {
                        emptyState
                    } else {
                        HarmonyCard("정확도 요약", systemImage: "chart.bar.fill") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: Theme.Spacing.lg) {
                                    ForEach(ChordGenerator.Interval.allCases, id: \.self) { interval in
                                        intervalSummary(for: interval)
                                    }
                                }

                                if let message = weakerIntervalMessage {
                                    Text(message)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }

                        HarmonyCard("최근 기록", systemImage: "clock") {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                ForEach(attempts.prefix(20), id: \.persistentModelID) { attempt in
                                    HStack {
                                        Text("\(attempt.targetNoteName) (\(ChordGenerator.Interval.from(storageKey: attempt.intervalRawValue)?.koreanLabel ?? attempt.intervalRawValue))")
                                        Spacer()
                                        Text(String(format: "%.0f%% 정확", attempt.onPitchRatio * 100))
                                        Text(String(format: "평균 ±%.0fcent", attempt.averageAbsCentsOffset))
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("기록")
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("아직 기록 없음")
                .font(Theme.Typography.headline)
            Text("연습 탭에서 채점을 마치면 여기에 기록이 쌓여요")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func attempts(for interval: ChordGenerator.Interval) -> [PracticeAttempt] {
        attempts.filter { $0.intervalRawValue == interval.storageKey }
    }

    private func averageOnPitchRatio(_ list: [PracticeAttempt]) -> Double? {
        guard !list.isEmpty else { return nil }
        return list.map(\.onPitchRatio).reduce(0, +) / Double(list.count)
    }

    /// 성부(베이스/3도/5도)별 평균 정확도 중 가장 낮은 것과 가장 높은 것의 차이가 뚜렷하면
    /// (10%p 이상) 어느 성부에서 더 자주 벗어나는지 알려준다 — PRD 페르소나 시나리오의
    /// "5도 화음에서 정확도가 낮음을 확인" 같은 걸 구현한 것. 기록이 아직 없는 성부(예: 베이스를
    /// 아직 한 번도 채점 안 함)는 비교 대상에서 자연히 빠진다(averageOnPitchRatio가 nil이므로).
    private var weakerIntervalMessage: String? {
        let averages = ChordGenerator.Interval.allCases.compactMap { interval in
            averageOnPitchRatio(attempts(for: interval)).map { (interval, $0) }
        }
        guard averages.count >= 2,
              let weakest = averages.min(by: { $0.1 < $1.1 }),
              let strongest = averages.max(by: { $0.1 < $1.1 }),
              strongest.1 - weakest.1 > 0.1 else { return nil }
        return "\(weakest.0.koreanLabel) 화음에서 더 자주 벗어나는 편이에요"
    }

    @ViewBuilder
    private func intervalSummary(for interval: ChordGenerator.Interval) -> some View {
        let list = attempts(for: interval)
        VStack(alignment: .leading, spacing: 2) {
            Text(interval.koreanLabel).font(Theme.Typography.caption).foregroundStyle(.secondary)
            if let average = averageOnPitchRatio(list) {
                Text(String(format: "%.0f%% (%d회)", average * 100, list.count))
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("기록 없음").font(Theme.Typography.caption).foregroundStyle(.secondary)
            }
        }
    }
}
