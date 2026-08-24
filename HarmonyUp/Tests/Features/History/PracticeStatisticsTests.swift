import XCTest
@testable import HarmonyUp

/// 기록 탭이 보여줄 통계 — 스트릭, 자주 틀리는 음, 음정 편향. SwiftData 모델(@Model)을 직접
/// 받지 않고 값만 받는 순수 함수로 둬서, 저장소 없이 테스트할 수 있게 했다.
final class PracticeStatisticsTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    /// 2026-08-24 12:00 — 테스트가 "오늘"로 삼는 기준 시각. 실제 현재 시각에 의존하면
    /// 자정 근처에서 테스트가 흔들린다.
    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 12))!
    }

    private func daysAgo(_ days: Int, hour: Int = 12) -> Date {
        calendar.date(byAdding: .day, value: -days, to: calendar.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: hour))!)!
    }

    // MARK: - 연속 연습 일수

    func testStreakIsZeroWithoutSessions() {
        XCTAssertEqual(PracticeStatistics.streakDays(sessionDates: [], today: today, calendar: calendar), 0)
    }

    func testStreakCountsToday() {
        XCTAssertEqual(PracticeStatistics.streakDays(sessionDates: [daysAgo(0)], today: today, calendar: calendar), 1)
    }

    func testStreakCountsConsecutiveDays() {
        let dates = [daysAgo(0), daysAgo(1), daysAgo(2)]
        XCTAssertEqual(PracticeStatistics.streakDays(sessionDates: dates, today: today, calendar: calendar), 3)
    }

    /// 같은 날 여러 번 연습해도 하루로 센다.
    func testMultipleSessionsSameDayCountOnce() {
        let dates = [daysAgo(0, hour: 9), daysAgo(0, hour: 14), daysAgo(0, hour: 21)]
        XCTAssertEqual(PracticeStatistics.streakDays(sessionDates: dates, today: today, calendar: calendar), 1)
    }

    /// 오늘 아직 안 했어도 어제까지 이어졌으면 스트릭은 살아있다 — 하루가 끝나기 전에
    /// "연속 3일"이 0으로 떨어져 보이면 오히려 연습할 마음이 꺾인다.
    func testStreakSurvivesWhenTodayNotPracticedYet() {
        let dates = [daysAgo(1), daysAgo(2)]
        XCTAssertEqual(PracticeStatistics.streakDays(sessionDates: dates, today: today, calendar: calendar), 2)
    }

    /// 이틀 이상 비면 끊긴다.
    func testStreakBreaksAfterTwoDayGap() {
        let dates = [daysAgo(2), daysAgo(3)]
        XCTAssertEqual(PracticeStatistics.streakDays(sessionDates: dates, today: today, calendar: calendar), 0)
    }

    func testStreakStopsAtGap() {
        // 오늘, 어제 연습 -> 그 앞은 하루 비었다(3일 전).
        let dates = [daysAgo(0), daysAgo(1), daysAgo(3), daysAgo(4)]
        XCTAssertEqual(PracticeStatistics.streakDays(sessionDates: dates, today: today, calendar: calendar), 2)
    }

    // MARK: - 자주 틀리는 음

    func testNoOffTargetsWhenNothingRepeats() {
        let samples = [(midiNote: 52, cents: -40.0), (midiNote: 55, cents: 50.0)]
        XCTAssertTrue(PracticeStatistics.frequentOffTargets(samples).isEmpty)
    }

    /// 같은 음에서 반복해 벗어나면 그 음과 평균 편차를 알려준다 — 부호를 살려야
    /// "낮게 부른다"까지 말할 수 있다.
    func testRepeatedOffTargetIsReportedWithSignedAverage() {
        let samples = [
            (midiNote: 53, cents: -40.0),
            (midiNote: 53, cents: -36.0),
            (midiNote: 53, cents: -38.0),
            (midiNote: 52, cents: 45.0),
        ]
        let result = PracticeStatistics.frequentOffTargets(samples)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].midiNote, 53)
        XCTAssertEqual(result[0].occurrences, 3)
        XCTAssertEqual(result[0].averageCents, -38, accuracy: 0.5)
    }

    /// 여러 음이 걸리면 자주 틀린 순서대로, 개수가 같으면 더 크게 벗어난 쪽이 먼저.
    func testOffTargetsSortedByFrequencyThenDeviation() {
        let samples = [
            (midiNote: 52, cents: 40.0), (midiNote: 52, cents: 42.0),
            (midiNote: 53, cents: -80.0), (midiNote: 53, cents: -82.0),
            (midiNote: 55, cents: 50.0), (midiNote: 55, cents: 52.0), (midiNote: 55, cents: 48.0),
        ]
        let result = PracticeStatistics.frequentOffTargets(samples)
        XCTAssertEqual(result.map(\.midiNote), [55, 53, 52])
    }

    func testOffTargetsRespectLimit() {
        let samples = (0..<10).flatMap { index in
            [(midiNote: 50 + index, cents: 60.0), (midiNote: 50 + index, cents: 60.0)]
        }
        XCTAssertEqual(PracticeStatistics.frequentOffTargets(samples, limit: 3).count, 3)
    }

    // MARK: - 음정 편향

    func testBiasDetectsSharpTendency() {
        XCTAssertEqual(PracticeStatistics.bias(signedOffsets: [28, 32, 30]), .sharp(30))
    }

    func testBiasDetectsFlatTendency() {
        XCTAssertEqual(PracticeStatistics.bias(signedOffsets: [-28, -32, -30]), .flat(30))
    }

    /// 높게/낮게가 섞여 상쇄되면 편향이 아니다 — 억지로 한쪽을 말하면 조언이 틀린다.
    func testBiasIsBalancedWhenOffsetsCancel() {
        XCTAssertEqual(PracticeStatistics.bias(signedOffsets: [40, -40, 35, -35]), .balanced)
    }

    /// 편차가 아주 작으면 편향이라 부르지 않는다(허용 오차 안의 잔떨림).
    func testSmallOffsetIsBalanced() {
        XCTAssertEqual(PracticeStatistics.bias(signedOffsets: [5, -3, 4]), .balanced)
    }

    func testBiasOnEmptyInputIsBalanced() {
        XCTAssertEqual(PracticeStatistics.bias(signedOffsets: []), .balanced)
    }

    // MARK: - 성부별 대표 시도

    private struct FakeAttempt: Equatable {
        let interval: ChordGenerator.Interval
        let date: Date
        let ratio: Double
    }

    private func summaries(_ items: [FakeAttempt]) -> [(interval: ChordGenerator.Interval, item: FakeAttempt, count: Int)] {
        PracticeStatistics.latestPerVoice(items, interval: { $0.interval }, date: { $0.date })
    }

    /// "다시 부르기"로 같은 성부를 여러 번 채점하면, 대표는 **가장 최근 것**이고 횟수는 전부
    /// 세어야 한다 — 이 규칙이 깨지면 사용자 눈에는 "다시 부른 게 기록이 안 됐다"로 보인다
    /// (2026-08-24 제보의 표시 쪽 절반).
    func testLatestPerVoicePicksMostRecentAndCountsRepeats() {
        let items = [
            FakeAttempt(interval: .third, date: daysAgo(0, hour: 9), ratio: 0.52),
            FakeAttempt(interval: .third, date: daysAgo(0, hour: 10), ratio: 0.71),
            FakeAttempt(interval: .third, date: daysAgo(0, hour: 11), ratio: 0.88),
        ]
        let result = summaries(items)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].item.ratio, 0.88, "가장 최근 시도가 대표가 아니다")
        XCTAssertEqual(result[0].count, 3, "반복 횟수가 안 세어졌다")
    }

    /// 성부가 섞여 있으면 각각 대표를 하나씩, 순서는 악보와 같은 음높이 내림차순.
    func testLatestPerVoiceFollowsDisplayOrder() {
        let items = [
            FakeAttempt(interval: .bass, date: daysAgo(0, hour: 9), ratio: 0.6),
            FakeAttempt(interval: .fifth, date: daysAgo(0, hour: 10), ratio: 0.7),
            FakeAttempt(interval: .third, date: daysAgo(0, hour: 11), ratio: 0.8),
        ]
        XCTAssertEqual(summaries(items).map(\.interval), ChordGenerator.Interval.displayOrder)
        XCTAssertTrue(summaries(items).allSatisfy { $0.count == 1 })
    }

    /// 한 번도 안 부른 성부는 아예 빠진다 — 0%로 채워 넣으면 "못 불렀다"로 오해된다.
    func testUnpracticedVoicesAreOmitted() {
        let items = [FakeAttempt(interval: .third, date: daysAgo(0), ratio: 0.8)]
        let result = summaries(items)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].interval, .third)
    }

    func testLatestPerVoiceOnEmptyInput() {
        XCTAssertTrue(summaries([]).isEmpty)
    }
}
