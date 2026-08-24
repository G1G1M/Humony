import XCTest
import SwiftData
@testable import HarmonyUp

/// "따라 부르기를 다시 해도 기록 탭에 안 남는다"는 제보(2026-08-24)를 재현/고정한다.
/// 같은 녹음에서 성부를 바꾸거나 같은 성부를 다시 불러도, 시도 하나하나가 **전부** 세션 아래
/// 쌓여야 한다.
final class PracticeAttemptRelationshipTests: XCTestCase {

    /// 실제 저장소를 건드리지 않는 메모리 전용 컨테이너 — 관계가 제대로 이어지는지만 본다.
    private func makeContext() throws -> ModelContext {
        let schema = Schema([PracticeSession.self, PracticeAttempt.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: configuration))
    }

    private func makeSession(in context: ModelContext) -> PracticeSession {
        let session = PracticeSession(
            date: Date(),
            keyName: "C장조",
            melodyMIDINotes: [60, 62, 64],
            melodyDurations: [0.3, 0.3, 0.3],
            harmonyMIDINotes: ["third": [52, 53, 52]]
        )
        context.insert(session)
        return session
    }

    private func makeAttempt(interval: ChordGenerator.Interval, ratio: Double) -> PracticeAttempt {
        PracticeAttempt(
            date: Date(),
            intervalRawValue: interval.storageKey,
            onPitchRatio: ratio,
            averageAbsCentsOffset: 20,
            averageSignedCentsOffset: 10,
            targetNoteCount: 3,
            missedCount: 0,
            extraCount: 0,
            offTargetMIDINotes: [],
            offTargetCents: [],
            missedMIDINotes: []
        )
    }

    /// 성부를 바꿔가며 채점하면 한 세션 아래에 시도가 쌓여야 한다.
    func testMultipleAttemptsAccumulateUnderOneSession() throws {
        let context = try makeContext()
        let session = makeSession(in: context)

        for (interval, ratio) in [(ChordGenerator.Interval.third, 0.82), (.fifth, 0.71), (.bass, 0.64)] {
            let attempt = makeAttempt(interval: interval, ratio: ratio)
            context.insert(attempt)
            attempt.session = session
        }
        try context.save()

        XCTAssertEqual(session.attempts.count, 3, "성부별 시도가 세션 아래 다 쌓이지 않았다")
        XCTAssertEqual(Set(session.attempts.map(\.intervalRawValue)), ["third", "fifth", "bass"])
    }

    /// **제보의 핵심** — 같은 성부를 "다시 부르기"로 여러 번 채점해도 시도가 각각 남아야 한다.
    /// 덮어쓰거나 무시되면 안 된다.
    func testRepeatedAttemptsOnSameVoiceAreAllKept() throws {
        let context = try makeContext()
        let session = makeSession(in: context)

        for ratio in [0.52, 0.71, 0.88] {
            let attempt = makeAttempt(interval: .third, ratio: ratio)
            context.insert(attempt)
            attempt.session = session
        }
        try context.save()

        XCTAssertEqual(session.attempts.count, 3, "같은 성부를 다시 불렀는데 시도가 남지 않았다")
        XCTAssertEqual(Set(session.attempts.map(\.onPitchRatio)), [0.52, 0.71, 0.88])
    }

    /// 저장소에서 다시 읽어와도 관계가 유지되는지 — 기록 탭은 세션을 쿼리해서 그 아래 시도를
    /// 읽으므로, 이 왕복이 깨지면 화면에 아무것도 안 뜬다.
    func testAttemptsSurviveRefetch() throws {
        let context = try makeContext()
        let session = makeSession(in: context)
        let attempt = makeAttempt(interval: .third, ratio: 0.82)
        context.insert(attempt)
        attempt.session = session
        try context.save()

        let refetched = try context.fetch(FetchDescriptor<PracticeSession>())
        XCTAssertEqual(refetched.count, 1)
        XCTAssertEqual(refetched.first?.attempts.count, 1)

        // 시도 쪽에서도 세션이 보여야 한다(기록 탭이 시도를 직접 쿼리해 세션별로 묶는 경우).
        let attempts = try context.fetch(FetchDescriptor<PracticeAttempt>())
        XCTAssertEqual(attempts.count, 1)
        XCTAssertNotNil(attempts.first?.session)
    }

    /// 지금 프로덕션 코드(`saveAttempt`)는 관계를 **insert 전에** 건다. SwiftData에서 아직
    /// 컨텍스트에 없는 객체의 관계를 먼저 설정하면 역관계가 갱신되지 않는 경우가 있어서,
    /// 그 순서로도 안전한지 따로 확인해둔다.
    func testRelationshipSetBeforeInsertStillLinks() throws {
        let context = try makeContext()
        let session = makeSession(in: context)

        let attempt = makeAttempt(interval: .fifth, ratio: 0.7)
        attempt.session = session          // 관계 먼저
        context.insert(attempt)            // 그다음 insert
        try context.save()

        XCTAssertEqual(session.attempts.count, 1, "insert 전에 관계를 걸면 세션에 안 붙는다")
    }
}
