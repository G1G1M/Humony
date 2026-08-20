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
}
