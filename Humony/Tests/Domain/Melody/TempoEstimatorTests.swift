import XCTest
@testable import Humony

/// 지금 `RhythmQuantizer`는 "전체 음 길이의 중앙값 = 1박"이라는 상대적 기준만 쓴다 — 8분음표가
/// 지배적인 노래에서는 그 8분음표가 4분음표로 표기되고, 마디가 실제 리듬과 어긋난다. 실제 박을
/// 추정해서 그 그리드에 맞추려는 것이 이 타입의 목적이다.
final class TempoEstimatorTests: XCTestCase {

    /// 시작 시각 배열을 간격(초)으로부터 만든다 — 테스트에서 리듬을 읽기 쉽게 적으려고.
    private func onsets(fromIntervals intervals: [Double], start: Double = 0) -> [Double] {
        var result = [start]
        for interval in intervals {
            result.append(result.last! + interval)
        }
        return result
    }

    // MARK: - 추정 불가

    func testTooFewOnsetsReturnsNil() {
        XCTAssertNil(TempoEstimator.estimate(onsetTimes: []))
        XCTAssertNil(TempoEstimator.estimate(onsetTimes: [0.0]))
        XCTAssertNil(TempoEstimator.estimate(onsetTimes: [0.0, 0.5]))
    }

    // MARK: - 균일한 리듬

    /// 0.5초 간격 = 120BPM. 같은 간격을 0.25초(240BPM)나 1.0초(60BPM)로도 설명할 수 있지만,
    /// 240BPM은 사람이 부르는 범위를 벗어나고 60BPM은 모든 음을 8분음표로 만든다 — 가장
    /// 자연스러운 해석은 "간격 하나가 1박"이다.
    func testUniformHalfSecondIntervalsAre120BPM() throws {
        let estimate = try XCTUnwrap(TempoEstimator.estimate(
            onsetTimes: onsets(fromIntervals: Array(repeating: 0.5, count: 7))
        ))
        XCTAssertEqual(estimate.beatDuration, 0.5, accuracy: 0.03)
        XCTAssertEqual(estimate.bpm, 120, accuracy: 5)
        XCTAssertGreaterThan(estimate.confidence, 0.9)
    }

    func testUniformOneSecondIntervalsAre60BPM() throws {
        let estimate = try XCTUnwrap(TempoEstimator.estimate(
            onsetTimes: onsets(fromIntervals: Array(repeating: 1.0, count: 7))
        ))
        XCTAssertEqual(estimate.beatDuration, 1.0, accuracy: 0.05)
        XCTAssertEqual(estimate.bpm, 60, accuracy: 5)
    }

    // MARK: - 섞인 음표 길이 (핵심)

    /// 8분음표와 4분음표가 섞여도 1박은 4분음표여야 한다 — 중앙값 방식(현재 RhythmQuantizer)은
    /// 8분음표가 더 많으면 그걸 1박으로 잡아버린다.
    func testMixedEighthAndQuarterFindsQuarterAsBeat() throws {
        // ♪♪♩ ♪♪♩ ♪♪♩ — 8분음표(0.25초)가 개수로는 더 많다.
        let intervals = Array(repeating: [0.25, 0.25, 0.5], count: 4).flatMap { $0 }
        let estimate = try XCTUnwrap(TempoEstimator.estimate(onsetTimes: onsets(fromIntervals: intervals)))
        XCTAssertEqual(estimate.beatDuration, 0.5, accuracy: 0.03)
        XCTAssertGreaterThan(estimate.confidence, 0.8)
    }

    /// 2분음표(2박)가 섞여도 박은 그대로다.
    func testMixedWithHalfNotes() throws {
        let intervals: [Double] = [0.5, 0.5, 1.0, 0.5, 0.5, 1.0, 0.5, 0.5, 1.0]
        let estimate = try XCTUnwrap(TempoEstimator.estimate(onsetTimes: onsets(fromIntervals: intervals)))
        XCTAssertEqual(estimate.beatDuration, 0.5, accuracy: 0.03)
    }

    // MARK: - 사람이 부른 흔들림

    /// 사람은 기계가 아니라 간격이 몇 %씩 흔들린다 — 그 정도로 추정이 무너지면 쓸모가 없다.
    func testToleratesHumanTimingJitter() throws {
        let jitter: [Double] = [0.52, 0.48, 0.51, 0.49, 0.53, 0.47, 0.50]
        let estimate = try XCTUnwrap(TempoEstimator.estimate(onsetTimes: onsets(fromIntervals: jitter)))
        XCTAssertEqual(estimate.beatDuration, 0.5, accuracy: 0.04)
        XCTAssertGreaterThan(estimate.confidence, 0.8)
    }

    // MARK: - 자유 리듬

    /// 무반주로 자유롭게 부르면 박이 없을 수 있다 — 억지로 격자에 맞추면 오히려 악보가
    /// 더 이상해진다. 확신이 낮다는 걸 호출부가 알 수 있어야 한다(그러면 기존 중앙값 방식으로
    /// 폴백한다).
    func testIrregularRhythmHasLowConfidence() {
        let irregular: [Double] = [0.31, 0.87, 0.44, 1.13, 0.62, 0.29, 0.95]
        let estimate = TempoEstimator.estimate(onsetTimes: onsets(fromIntervals: irregular))
        if let estimate {
            XCTAssertLessThan(
                estimate.confidence,
                RhythmQuantizer.minimumTempoConfidence,
                "자유 리듬인데 확신이 높아서 박 그리드로 강제된다"
            )
        }
    }

    // MARK: - BPM 범위

    /// 사람이 노래하는 범위를 벗어나는 해석은 고르지 않는다 — 같은 간격을 절반/2배 박으로도
    /// 설명할 수 있어서(박 모호성), 범위 제한이 실질적인 타이브레이커 역할을 한다.
    func testEstimatedBPMStaysInSingableRange() throws {
        for interval in [0.3, 0.4, 0.5, 0.75, 1.0, 1.2] {
            let estimate = try XCTUnwrap(TempoEstimator.estimate(
                onsetTimes: onsets(fromIntervals: Array(repeating: interval, count: 7))
            ))
            XCTAssertGreaterThanOrEqual(estimate.bpm, TempoEstimator.minimumBPM - 1)
            XCTAssertLessThanOrEqual(estimate.bpm, TempoEstimator.maximumBPM + 1)
        }
    }

    // MARK: - 박 단위 길이 변환

    /// 추정한 박으로 실제 음 길이를 "몇 박인지"로 바꾼다 — RhythmQuantizer가 이 값을 음표
    /// 모양으로 옮긴다.
    func testBeatsForDurationSnapsToNearestNoteValue() throws {
        let estimate = try XCTUnwrap(TempoEstimator.estimate(
            onsetTimes: onsets(fromIntervals: Array(repeating: 0.5, count: 7))
        ))
        XCTAssertEqual(estimate.beats(forDuration: 0.5), 1.0, accuracy: 0.01)
        XCTAssertEqual(estimate.beats(forDuration: 0.25), 0.5, accuracy: 0.01)
        XCTAssertEqual(estimate.beats(forDuration: 1.0), 2.0, accuracy: 0.01)
        // 살짝 벗어난 값도 비율 그대로 — 음표 모양으로 스냅하는 건 RhythmQuantizer의 몫이다.
        XCTAssertEqual(estimate.beats(forDuration: 0.55), 1.1, accuracy: 0.01)
    }
}
