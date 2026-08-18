import SwiftUI
import SwiftData
import Charts

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

                        HarmonyCard("정확도 추이", systemImage: "chart.xyaxis.line") {
                            accuracyTrendChart
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

    // MARK: - 정확도 추이 차트

    /// 성부(베이스/3도/5도)마다 고정된 정체성 색 — 채점 상태색(pitchGood 초록/pitchBad 빨강,
    /// Theme.swift)이나 "정확도 요약" 카드의 경고 문구 색(주황, weakerIntervalMessage)과 절대
    /// 안 겹치게 골랐다. 차트 범례는 "이 선이 어느 성부인지" 구분하는 용도일 뿐, 정확/부정확
    /// 같은 상태 의미를 담으면 안 되기 때문이다(상태색은 상태 전용으로 예약).
    private static let intervalColors: [ChordGenerator.Interval: Color] = [
        .bass: .blue,
        .third: .teal,
        .fifth: .purple,
    ]

    private struct AccuracyPoint: Identifiable {
        let id = UUID()
        let date: Date
        let interval: ChordGenerator.Interval
        let onPitchPercent: Double
    }

    /// 시간순(오래된 것 -> 최근)으로 정렬 — `attempts`는 최근 기록 목록 용도로 최신순으로
    /// 정렬돼 있지만(위 `@Query`), LineMark는 데이터가 주어진 순서 그대로 이어 그리므로
    /// 차트에서는 반드시 오름차순이어야 선이 왼쪽에서 오른쪽으로 자연스럽게 이어진다.
    private var accuracyPoints: [AccuracyPoint] {
        attempts
            .sorted { $0.date < $1.date }
            .compactMap { attempt in
                guard let interval = ChordGenerator.Interval.from(storageKey: attempt.intervalRawValue) else { return nil }
                return AccuracyPoint(date: attempt.date, interval: interval, onPitchPercent: attempt.onPitchRatio * 100)
            }
    }

    /// "정확도가 나아지고 있나?"를 한눈에 보여주는 성부별 정확도 추이 — 시도 하나하나를 텍스트로
    /// 나열하는 "최근 기록" 카드와 달리, 여러 시도에 걸친 변화를 한 그림으로 압축해서 보여준다.
    /// 성부(베이스/3도/5도) 3개가 서로 다른 계열이라 색만으로 구분하지 않고 심볼 모양도 같이
    /// 다르게 줘서(범례+symbol 이중 인코딩) 색맹이어도 구분 가능하게 했다.
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
            ChordGenerator.Interval.bass.koreanLabel: Self.intervalColors[.bass]!,
            ChordGenerator.Interval.third.koreanLabel: Self.intervalColors[.third]!,
            ChordGenerator.Interval.fifth.koreanLabel: Self.intervalColors[.fifth]!,
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
        .accessibilityLabel("성부별 정확도 추이 그래프, 최근 기록 목록과 같은 데이터를 그래프로 보여줍니다")
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
