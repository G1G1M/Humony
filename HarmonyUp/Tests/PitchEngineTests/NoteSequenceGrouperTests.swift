import XCTest
@testable import HarmonyUp

final class NoteSequenceGrouperTests: XCTestCase {

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(NoteSequenceGrouper.group([]).isEmpty)
    }

    func testAllDifferentNotesStayUngrouped() {
        let result = NoteSequenceGrouper.group([261.63, 293.66, 329.63])
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.holdCount == 1 })
    }

    // 멜로디가 같은 음을 3번 반복하면(베이스도 그때마다 같은 음), 매번 다시 어택하는 대신
    // 하나의 지속음(holdCount 3)으로 묶여야 한다 — 이게 이 기능의 핵심 계약이다.
    func testRepeatedNoteGroupsIntoOneHeldNote() {
        let result = NoteSequenceGrouper.group([261.63, 261.63, 261.63])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.holdCount, 3)
        XCTAssertEqual(result.first?.frequency ?? 0, 261.63, accuracy: 0.01)
    }

    // 반복 후 다른 음으로 바뀌면 그 지점에서 새 그룹이 시작돼야 한다(중간에 끊긴 반복까지
    // 하나로 뭉개버리면 안 됨).
    func testRepeatedNoteFollowedByDifferentNoteStartsNewGroup() {
        let result = NoteSequenceGrouper.group([261.63, 261.63, 293.66])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].holdCount, 2)
        XCTAssertEqual(result[1].holdCount, 1)
    }

    // 몇 cent 이내의 부동소수점 오차는 "같은 음"으로 취급해야 한다(계산 과정의 반올림 오차가
    // 진짜로 다른 음처럼 그룹을 쪼개버리면 안 됨).
    func testNearlyIdenticalFrequenciesWithinToleranceGroupTogether() {
        let result = NoteSequenceGrouper.group([440.0, 440.05, 439.97])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.holdCount, 3)
    }

    // 명확히 다른 음(반음 이상 차이)은 그룹으로 묶이면 안 된다 — 허용오차가 너무 관대해서
    // 실제로 다른 음까지 뭉개버리는 회귀를 잡는다.
    func testClearlyDifferentFrequenciesDoNotGroup() {
        let result = NoteSequenceGrouper.group([440.0, 466.16]) // A4 -> A#4, 반음 차이
        XCTAssertEqual(result.count, 2)
    }

    // 총 스텝 개수(holdCount의 합)는 항상 원래 입력 길이와 같아야 한다 — 재생 총 길이가
    // 묶기 전후로 달라지지 않는다는 걸 보장한다.
    func testTotalHoldCountMatchesInputLength() {
        let input = [261.63, 261.63, 293.66, 329.63, 329.63, 329.63]
        let result = NoteSequenceGrouper.group(input)
        XCTAssertEqual(result.reduce(0) { $0 + $1.holdCount }, input.count)
    }
}
