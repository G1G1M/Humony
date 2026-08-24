import XCTest
@testable import HarmonyUp

final class ScoreTimelineTests: XCTestCase {

    private func step(_ midiNote: Int, onset: Double?, duration: Double?) -> MelodyStep {
        MelodyStep(
            noteName: NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?",
            midiNote: midiNote,
            harmonyVoices: nil,
            harmony: nil,
            onsetTime: onset,
            duration: duration
        )
    }

    // MARK: - 표시용 타임라인 (149절)

    /// 음표 길이는 "부른 시간"이 아니라 **다음 음까지의 간격**이다. 무음 없이 이어 부르면
    /// 쉼표 없이 간격이 그대로 음표 길이가 된다.
    func testContiguousNotesUseTheIntervalToTheNextOnset() {
        let steps = [
            step(60, onset: 0.0, duration: 0.45),
            step(62, onset: 0.5, duration: 0.45),
            step(64, onset: 1.0, duration: 0.60)
        ]

        let events = ScoreTimeline.events(from: steps)

        XCTAssertEqual(events, [
            .note(stepIndex: 0, start: 0.0, displayDuration: 0.5),
            .note(stepIndex: 1, start: 0.5, displayDuration: 0.5),
            .note(stepIndex: 2, start: 1.0, displayDuration: 0.60)   // 마지막 음만 자기 길이
        ])
    }

    /// 스타카토/숨쉬기로 생긴 뚜렷한 무음은 쉼표가 된다. **핵심 불변식: 음표 + 쉼표의 합이
    /// 간격과 같아야 한다** — 그래야 마디에 담긴 총 시간이 실제 노래와 맞는다.
    func testClearSilenceBecomesARestAndTotalTimeIsPreserved() {
        let steps = [
            step(60, onset: 0.0, duration: 0.20),   // 짧게 끊어 부름
            step(62, onset: 1.0, duration: 0.50)
        ]

        let events = ScoreTimeline.events(from: steps)

        XCTAssertEqual(events, [
            .note(stepIndex: 0, start: 0.0, displayDuration: 0.20),
            .rest(start: 0.20, duration: 0.80),
            .note(stepIndex: 1, start: 1.0, displayDuration: 0.50)
        ])

        // 첫 음 + 쉼표 = 다음 음까지의 간격(1.0초)
        XCTAssertEqual(0.20 + 0.80, 1.0, accuracy: 1e-9)
    }

    /// 아주 짧은 틈은 쉼표로 그리지 않는다 — 레가토로 이어 부른 것으로 본다.
    func testTinyGapIsAbsorbedIntoTheNoteInsteadOfBecomingARest() {
        let steps = [
            step(60, onset: 0.0, duration: 0.45),   // 틈 0.05초
            step(62, onset: 0.5, duration: 0.50)
        ]

        let events = ScoreTimeline.events(from: steps)

        XCTAssertEqual(events, [
            .note(stepIndex: 0, start: 0.0, displayDuration: 0.5),
            .note(stepIndex: 1, start: 0.5, displayDuration: 0.50)
        ])
    }

    /// `stepIndex`는 원본 배열 기준이어야 한다 — 화음을 찾을 때 이 인덱스로 되짚는다.
    func testStepIndexRefersToTheOriginalArrayEvenWhenSomeStepsAreSkipped() {
        let steps = [
            step(60, onset: nil, duration: 0.5),    // onsetTime 없음 — 악보에 못 그린다
            step(62, onset: 0.0, duration: 0.5),
            step(64, onset: 0.5, duration: 0.5)
        ]

        let events = ScoreTimeline.events(from: steps)

        XCTAssertEqual(events, [
            .note(stepIndex: 1, start: 0.0, displayDuration: 0.5),
            .note(stepIndex: 2, start: 0.5, displayDuration: 0.5)
        ])
    }

    func testEmptyStepsProduceNoEvents() {
        XCTAssertTrue(ScoreTimeline.events(from: []).isEmpty)
    }

    // MARK: - 재생 위치 -> 하이라이트할 자리 (149절)

    /// 인덱스는 **이벤트 배열 기준**이다 — `render.js`의 `setActiveStep`이 그려진 음표 배열을
    /// 그대로 인덱싱하므로, 쉼표도 한 자리를 차지한다.
    func testActiveEventIndexFollowsPlaybackPosition() {
        let steps = [
            step(60, onset: 0.0, duration: 0.20),
            step(62, onset: 1.0, duration: 0.50)
        ]
        let events = ScoreTimeline.events(from: steps)  // [음표, 쉼표, 음표]

        XCTAssertEqual(ScoreTimeline.activeEventIndex(at: 0.10, events: events), 0)
        XCTAssertNil(ScoreTimeline.activeEventIndex(at: 0.50, events: events), "쉼표 구간에서는 아무것도 강조하지 않는다")
        XCTAssertEqual(ScoreTimeline.activeEventIndex(at: 1.20, events: events), 2)
    }

    func testActiveEventIndexIsNilOutsideTheSong() {
        let steps = [step(60, onset: 0.5, duration: 0.5)]
        let events = ScoreTimeline.events(from: steps)

        XCTAssertNil(ScoreTimeline.activeEventIndex(at: 0.10, events: events), "첫 음 전")
        XCTAssertNil(ScoreTimeline.activeEventIndex(at: 5.00, events: events), "마지막 음 이후")
        XCTAssertNil(ScoreTimeline.activeEventIndex(at: 0.60, events: []), "이벤트가 없으면 nil")
    }
}
