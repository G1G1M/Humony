import XCTest
@testable import HarmonyUp

final class AudioGainTests: XCTestCase {

    func testNormalizeLoudnessRaisesRMSToTarget() {
        // 사인파의 RMS는 진폭의 1/√2 — 진폭 0.1이면 RMS ≈ 0.0707.
        let samples: [Float] = (0..<1000).map { Float(0.1 * sin(2.0 * Double.pi * 10.0 * Double($0) / 1000.0)) }
        let normalized = AudioGain.normalizeLoudness(samples, targetRMS: 0.25, peakCeiling: 0.98)

        let rms = (normalized.reduce(Float(0)) { $0 + $1 * $1 } / Float(normalized.count)).squareRoot()
        XCTAssertEqual(rms, 0.25, accuracy: 0.01)
    }

    func testNormalizeLoudnessClampsToPeakCeilingWhenSpikeWouldClip() {
        // 대부분 조용한데(RMS를 낮게 만듦) 한 샘플만 아주 큰 "숨소리성 피크" — RMS 기준
        // 게인을 그대로 적용하면 그 피크가 1.0을 넘어 찢어진다. peakCeiling이 이걸 막아야 한다.
        var samples = [Float](repeating: 0.02, count: 1000)
        samples[500] = 0.9
        let normalized = AudioGain.normalizeLoudness(samples, targetRMS: 0.25, peakCeiling: 0.98)

        let peak = normalized.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 0.98 + 0.001)
    }

    func testNormalizeLoudnessSilentBufferReturnsUnchanged() {
        let samples: [Float] = [0, 0, 0]
        XCTAssertEqual(AudioGain.normalizeLoudness(samples), samples)
    }

    func testApplyFadeInOutRampsEdgesToZero() {
        let samples = [Float](repeating: 1.0, count: 100)
        let faded = AudioGain.applyFadeInOut(samples, fadeSampleCount: 10)

        XCTAssertEqual(faded[0], 0, accuracy: 0.0001)
        XCTAssertEqual(faded[faded.count - 1], 0, accuracy: 0.0001)
        // 페이드 구간 밖(중앙)은 원본 그대로 유지돼야 한다.
        XCTAssertEqual(faded[50], 1.0, accuracy: 0.0001)
    }

    func testApplyFadeInOutWithZeroCountReturnsUnchanged() {
        let samples: [Float] = [1, 1, 1]
        XCTAssertEqual(AudioGain.applyFadeInOut(samples, fadeSampleCount: 0), samples)
    }

    func testMixSumsTracksSampleBySample() {
        let a: [Float] = [0.1, 0.2, 0.3]
        let b: [Float] = [0.1, 0.1, 0.1]
        assertFloatArrayEqual(AudioGain.mix(tracks: [a, b]), [0.2, 0.3, 0.4], accuracy: 0.0001)
    }

    func testMixHandlesTracksOfDifferentLengthByTreatingMissingAsSilence() {
        let a: [Float] = [0.5, 0.5]
        let b: [Float] = [0.1]
        assertFloatArrayEqual(AudioGain.mix(tracks: [a, b]), [0.6, 0.5], accuracy: 0.0001)
    }

    func testMixOfEmptyTracksReturnsEmpty() {
        XCTAssertEqual(AudioGain.mix(tracks: []), [])
    }
}

// XCTestCase에 이름이 겹치는 멤버(예: XCTAssertEqual)를 추가하면 그 파일 안의 다른
// XCTAssertEqual 호출까지 오버로드 해석이 꼬여버린다(멤버가 전역 함수보다 먼저 탐색됨) —
// 그래서 이름을 아예 다르게 짓는다.
private func assertFloatArrayEqual(_ a: [Float], _ b: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, "배열 길이가 다릅니다", file: file, line: line)
    for (x, y) in zip(a, b) {
        XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line)
    }
}
