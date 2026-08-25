import XCTest
@testable import Humony

/// 부른 조성과 악보의 조성이 다를 수 있다 — 음역 때문에 편한 키로 옮겨 부르는 건 흔하다.
/// 정렬·교정 **전에** "얼마나 옮겨 불렀는지"부터 알아야 절대 음높이 비교가 의미를 갖는다 (155절).
final class TranspositionEstimatorTests: XCTestCase {

    /// 도레미파솔라시도 — 조옮김을 알아보기에 충분히 조성적인 멜로디.
    private let cMajorScale: [PitchedNote] = [60, 62, 64, 65, 67, 69, 71, 72]
        .map { PitchedNote(midiNote: $0, duration: 1.0) }

    private func transposed(_ notes: [PitchedNote], by semitones: Int) -> [PitchedNote] {
        notes.map { PitchedNote(midiNote: $0.midiNote + semitones, duration: $0.duration) }
    }

    // MARK: - 조옮김 양

    func testDetectsNoTranspositionWhenSungInTheSameKey() throws {
        let estimate = try XCTUnwrap(TranspositionEstimator.estimate(sung: cMajorScale, reference: cMajorScale))

        XCTAssertEqual(estimate.semitones, 0)
        XCTAssertGreaterThanOrEqual(estimate.confidence, TranspositionEstimator.minimumConfidence)
    }

    /// C장조 악보를 G장조로 부르면 모든 음이 7반음 위다. 절대 음높이로 그냥 맞추면 전부 어긋난다.
    func testDetectsUpwardTransposition() throws {
        let sung = transposed(cMajorScale, by: 7)

        let estimate = try XCTUnwrap(TranspositionEstimator.estimate(sung: sung, reference: cMajorScale))

        XCTAssertEqual(estimate.semitones, 7)
    }

    /// 낮게 부른 경우. 음이름 회전만 보면 7과 -5가 같아 보이므로 **옥타브까지 정해야** 한다.
    func testDetectsDownwardTransposition() throws {
        let sung = transposed(cMajorScale, by: -5)

        let estimate = try XCTUnwrap(TranspositionEstimator.estimate(sung: sung, reference: cMajorScale))

        XCTAssertEqual(estimate.semitones, -5)
    }

    /// 같은 조성인데 한 옥타브 아래로 부르는 경우(남성이 여성 음역 악보를 볼 때 흔하다).
    /// 음이름 분포는 완전히 같아서 회전은 0이고, 차이는 옥타브에서만 나온다.
    func testDetectsOctaveOnlyTransposition() throws {
        let sung = transposed(cMajorScale, by: -12)

        let estimate = try XCTUnwrap(TranspositionEstimator.estimate(sung: sung, reference: cMajorScale))

        XCTAssertEqual(estimate.semitones, -12)
    }

    // MARK: - 실제 녹음에 가까운 입력

    /// 곡을 끝까지 안 부르고 앞부분만 불러도 조옮김은 알 수 있어야 한다.
    func testWorksWhenOnlyPartOfTheScoreWasSung() throws {
        let sung = transposed(Array(cMajorScale.prefix(5)), by: 2)

        let estimate = try XCTUnwrap(TranspositionEstimator.estimate(sung: sung, reference: cMajorScale))

        XCTAssertEqual(estimate.semitones, 2)
    }

    /// 떨림이 만든 짧은 오탐 음이 몇 개 섞여도 견뎌야 한다(153절에서 실측한 상황).
    /// **길이 가중이 핵심이다** — 0.05초짜리 잡음이 1초짜리 음과 같은 표를 가지면 안 된다.
    func testShortSpuriousNotesDoNotFlipTheEstimate() throws {
        var sung = transposed(cMajorScale, by: 5)
        sung.insert(PitchedNote(midiNote: 70, duration: 0.05), at: 2)   // 조성 밖 오탐
        sung.append(PitchedNote(midiNote: 73, duration: 0.05))

        let estimate = try XCTUnwrap(TranspositionEstimator.estimate(sung: sung, reference: cMajorScale))

        XCTAssertEqual(estimate.semitones, 5)
    }

    // MARK: - 포기해야 하는 경우

    /// 다른 노래를 불렀거나 악보를 잘못 올린 경우. **억지로 맞추면 멀쩡한 채보를 악보 쪽으로
    /// 끌고 가 더 망가진다**(149절에 A#3 하나 고치려다 음표 경계까지 바뀌어 회귀가 났던 것과
    /// 같은 종류의 위험). 신뢰도가 낮게 나와야 호출부가 교정을 포기할 수 있다.
    func testUnrelatedMelodyGetsLowConfidence() throws {
        // 반음계 전체를 고르게 부르면 어느 회전에도 특별히 잘 맞지 않는다.
        let sung = (60...71).map { PitchedNote(midiNote: $0, duration: 1.0) }

        let estimate = TranspositionEstimator.estimate(sung: sung, reference: cMajorScale)

        XCTAssertLessThan(estimate?.confidence ?? 0, TranspositionEstimator.minimumConfidence)
    }

    func testReturnsNilForEmptyInput() {
        XCTAssertNil(TranspositionEstimator.estimate(sung: [], reference: cMajorScale))
        XCTAssertNil(TranspositionEstimator.estimate(sung: cMajorScale, reference: []))
    }
}
