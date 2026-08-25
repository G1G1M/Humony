import XCTest
@testable import Humony

/// 목표 음 시퀀스와 부른 음 시퀀스를 순서를 지키며 짝짓는 편집거리 정렬 (136절 채점기에서
/// 155절에 분리). 채점("얼마나 벗어났나")과 교정("이 음이 악보의 어느 음인가")이 같은 계산을
/// 필요로 해서 공유한다.
final class MelodyAlignerTests: XCTestCase {

    /// 값은 선형 거리 공간의 좌표다(cent). 반음 = 100.
    private func semitones(_ values: [Int]) -> [Double] {
        values.map { Double($0) * 100 }
    }

    func testPairsSequencesThatMatchExactly() {
        let pairs = MelodyAligner.align(
            targets: semitones([60, 62, 64]),
            sung: semitones([60, 62, 64]),
            gapPenalty: 600
        )

        XCTAssertEqual(pairs, [
            .init(targetIndex: 0, sungIndex: 0),
            .init(targetIndex: 1, sungIndex: 1),
            .init(targetIndex: 2, sungIndex: 2)
        ])
    }

    /// **순서대로 1:1(zip)로는 안 되는 이유**: 중간에서 음 하나를 빠뜨리면 그 뒤가 전부 한 칸씩
    /// 밀려 잘 부른 나머지가 모두 오답이 된다. 정렬은 빠진 자리만 공백으로 두고 뒤를 다시 맞춘다.
    func testAMissedNoteOnlyCostsThatOneSlot() {
        let pairs = MelodyAligner.align(
            targets: semitones([60, 62, 64, 65]),
            sung: semitones([60, 64, 65]),
            gapPenalty: 600
        )

        XCTAssertEqual(pairs, [
            .init(targetIndex: 0, sungIndex: 0),
            .init(targetIndex: 1, sungIndex: nil),   // 62를 안 불렀다
            .init(targetIndex: 2, sungIndex: 1),
            .init(targetIndex: 3, sungIndex: 2)
        ])
    }

    /// 목표에 없는 음을 하나 더 부른 경우 — 그 음만 군더더기로 남고 나머지 짝은 유지된다.
    func testAnExtraSungNoteIsMarkedWithoutShiftingTheRest() {
        let pairs = MelodyAligner.align(
            targets: semitones([60, 62]),
            sung: semitones([60, 71, 62]),
            gapPenalty: 600
        )

        XCTAssertEqual(pairs, [
            .init(targetIndex: 0, sungIndex: 0),
            .init(targetIndex: nil, sungIndex: 1),   // 71은 목표에 없다
            .init(targetIndex: 1, sungIndex: 2)
        ])
    }

    /// 한 옥타브 넘게 동떨어진 음은 짝짓지 않는다 — 짝지어 "1900cent 벗어났다"고 말하는 것보다
    /// "다른 음을 불렀다"로 세는 편이 정확하다. 이 경계를 정하는 게 `gapPenalty`다
    /// (누락+추가 한 쌍의 비용 = gapPenalty × 2).
    func testFarApartNotesAreNotPairedWhenSkippingIsCheaper() {
        let pairs = MelodyAligner.align(
            targets: semitones([60]),
            sung: semitones([84]),        // 2옥타브 위 = 2400cent > 600 × 2
            gapPenalty: 600
        )

        // 같은 자리의 누락과 추가 중 어느 쪽이 먼저 오는지는 되짚기 순서가 정한다(136절부터의
        // 동작 그대로다). 둘 다 "같은 시점"이라 채점·교정 어느 쪽 결과에도 영향을 주지 않는다.
        XCTAssertEqual(pairs, [
            .init(targetIndex: nil, sungIndex: 0),
            .init(targetIndex: 0, sungIndex: nil)
        ])
    }

    func testEverythingIsMissedWhenNothingWasSung() {
        let pairs = MelodyAligner.align(targets: semitones([60, 62]), sung: [], gapPenalty: 600)

        XCTAssertEqual(pairs, [
            .init(targetIndex: 0, sungIndex: nil),
            .init(targetIndex: 1, sungIndex: nil)
        ])
    }

    func testEverythingIsExtraWhenThereAreNoTargets() {
        let pairs = MelodyAligner.align(targets: [], sung: semitones([60]), gapPenalty: 600)

        XCTAssertEqual(pairs, [.init(targetIndex: nil, sungIndex: 0)])
    }

    func testEmptyInputProducesNoPairs() {
        XCTAssertEqual(MelodyAligner.align(targets: [], sung: [], gapPenalty: 600), [])
    }
}
