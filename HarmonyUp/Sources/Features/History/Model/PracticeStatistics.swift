import Foundation

/// 기록 탭이 보여줄 통계 — 연속 연습 일수, 자주 틀리는 음, 음정 편향.
///
/// SwiftData 모델(`PracticeSession` / `PracticeAttempt`)을 직접 받지 않고 값만 받는다 —
/// 저장소를 띄우지 않고 유닛테스트할 수 있게 하려는 것이고(이 프로젝트의 "판단 로직은 순수
/// 함수로" 원칙과 같은 이유), 뷰가 모델에서 값을 꺼내 넘기는 얇은 변환만 담당하게 된다.
enum PracticeStatistics {

    // MARK: - 연속 연습 일수

    /// 오늘(또는 어제)부터 거꾸로 하루도 빠지지 않은 날의 수.
    ///
    /// **오늘 아직 안 했으면 어제부터 센다**: 하루가 끝나기도 전에 "연속 3일"이 0으로 떨어져
    /// 보이면 오히려 연습할 마음이 꺾인다. 어제까지 이어졌다면 스트릭은 아직 살아있는 상태로
    /// 보여주고, 이틀 이상 비었을 때 비로소 끊어진 것으로 본다.
    static func streakDays(sessionDates: [Date], today: Date, calendar: Calendar = .current) -> Int {
        guard !sessionDates.isEmpty else { return 0 }

        // 같은 날 여러 번 연습해도 하루로 세려면 "날짜" 단위로 뭉쳐야 한다.
        let practicedDays = Set(sessionDates.map { calendar.startOfDay(for: $0) })
        let startOfToday = calendar.startOfDay(for: today)

        // 오늘 연습했으면 오늘부터, 아니면 어제부터 세기 시작한다. 어제도 안 했으면 0.
        var cursor: Date
        if practicedDays.contains(startOfToday) {
            cursor = startOfToday
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
                  practicedDays.contains(yesterday) {
            cursor = yesterday
        } else {
            return 0
        }

        var streak = 0
        while practicedDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    // MARK: - 성부별 대표 시도

    /// 성부별로 **가장 최근 시도**와 그 성부를 몇 번 불렀는지를 화면 순서
    /// (`ChordGenerator.Interval.displayOrder`)대로 돌려준다.
    ///
    /// 세션 행에 시도를 전부 나열하면 "3도 52% · 3도 71% · 3도 88%"처럼 한 행이 길어져
    /// 세션끼리 비교가 안 된다 — 대표 하나만 보여주되, 반복 횟수를 함께 줘서 "다시 부른 게
    /// 기록이 안 됐다"는 오해가 생기지 않게 한다(전체 목록은 세션 상세에 있다).
    ///
    /// `@Model` 타입을 직접 받지 않으려고 접근자를 받는다 — 저장소 없이 테스트하기 위해서다.
    static func latestPerVoice<T>(
        _ items: [T],
        interval: (T) -> ChordGenerator.Interval?,
        date: (T) -> Date
    ) -> [(interval: ChordGenerator.Interval, item: T, count: Int)] {
        ChordGenerator.Interval.displayOrder.compactMap { voice in
            let forVoice = items.filter { interval($0) == voice }
            guard let latest = forVoice.max(by: { date($0) < date($1) }) else { return nil }
            return (interval: voice, item: latest, count: forVoice.count)
        }
    }

    // MARK: - 자주 틀리는 음

    struct OffTargetNote: Equatable {
        let midiNote: Int
        let occurrences: Int
        /// 부호를 살린 평균 편차(cent) — 양수면 그 음을 높게, 음수면 낮게 부르는 경향.
        let averageCents: Double

        var noteName: String {
            NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?"
        }
    }

    /// 허용 오차를 벗어난 음들을 음높이별로 모아, 반복해서 틀리는 음을 알려준다.
    ///
    /// 성부 단위 평균("3도에서 더 자주 벗어남")보다 한 단계 구체적인 정보다 — "F3에서 평균
    /// 38cent 낮게 부른다"까지 나오면 다음에 무엇을 연습할지가 바로 정해진다.
    ///
    /// - Parameters:
    ///   - minimumOccurrences: 이 횟수 미만은 우연일 수 있어 빼둔다(기본 2 — 한 번은 실수,
    ///     두 번부터 경향).
    ///   - limit: 너무 많이 늘어놓으면 읽지 않는다.
    static func frequentOffTargets(
        _ samples: [(midiNote: Int, cents: Double)],
        minimumOccurrences: Int = 2,
        limit: Int = 3
    ) -> [OffTargetNote] {
        var centsByNote: [Int: [Double]] = [:]
        for sample in samples {
            centsByNote[sample.midiNote, default: []].append(sample.cents)
        }

        return centsByNote
            .filter { $0.value.count >= minimumOccurrences }
            .map { midiNote, cents in
                OffTargetNote(
                    midiNote: midiNote,
                    occurrences: cents.count,
                    averageCents: cents.reduce(0, +) / Double(cents.count)
                )
            }
            // 자주 틀린 순서대로, 횟수가 같으면 더 크게 벗어난 쪽을 먼저 보여준다.
            .sorted {
                $0.occurrences != $1.occurrences
                    ? $0.occurrences > $1.occurrences
                    : abs($0.averageCents) > abs($1.averageCents)
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - 음정 편향

    /// 전반적으로 높게/낮게 부르는 경향. 연관 값은 평균 편차의 크기(cent, 항상 양수).
    enum PitchBias: Equatable {
        case sharp(Double)
        case flat(Double)
        case balanced
    }

    /// 부호를 살린 편차들의 평균으로 방향을 판단한다 — 절대값 평균("평균 ±38cent")만으로는
    /// 높게 부르는지 낮게 부르는지 알 수 없는데, 그 방향이 실제로 고칠 방법을 가른다.
    ///
    /// 높게와 낮게가 섞여 상쇄되면 편향이 아니다(억지로 한쪽을 말하면 조언이 틀린다).
    /// - Parameter threshold: 이보다 작은 평균은 편향이라 부르지 않는다 — 허용 오차(35cent)
    ///   안의 잔떨림까지 "높게 부르는 편"이라고 말할 이유가 없다.
    static func bias(signedOffsets: [Double], threshold: Double = 10) -> PitchBias {
        guard !signedOffsets.isEmpty else { return .balanced }
        let average = signedOffsets.reduce(0, +) / Double(signedOffsets.count)
        guard abs(average) >= threshold else { return .balanced }
        return average > 0 ? .sharp(average) : .flat(-average)
    }
}
