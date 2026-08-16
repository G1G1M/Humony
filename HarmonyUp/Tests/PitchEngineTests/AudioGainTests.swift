import XCTest
@testable import HarmonyUp

final class AudioGainTests: XCTestCase {

    func testNormalizeScalesPeakToTarget() {
        let samples: [Float] = [0.1, -0.2, 0.05, -0.1]
        let normalized = AudioGain.normalize(samples, targetPeak: 0.95)

        let peak = normalized.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, 0.95, accuracy: 0.001)
    }

    func testNormalizePreservesRelativeShape() {
        let samples: [Float] = [0.1, -0.2, 0.05]
        let normalized = AudioGain.normalize(samples, targetPeak: 0.95)

        // 두 번째 값이 첫 번째의 -2배였다면, 정규화 후에도 그 비율이 유지돼야 한다.
        XCTAssertEqual(normalized[1] / normalized[0], -2.0, accuracy: 0.01)
    }

    func testNormalizeSilentBufferReturnsUnchanged() {
        let samples: [Float] = [0, 0, 0]
        XCTAssertEqual(AudioGain.normalize(samples), samples)
    }

    func testMixAndNormalizeSumsTracksToShortestLength() {
        let a: [Float] = [0.1, 0.1, 0.1, 0.1]
        let b: [Float] = [0.1, 0.1, 0.1] // 더 짧음

        let mixed = AudioGain.mixAndNormalize([a, b], targetPeak: 0.9)

        XCTAssertEqual(mixed.count, 3) // 짧은 쪽 길이에 맞춰짐
        let peak = mixed.map { abs($0) }.max() ?? 0
        XCTAssertEqual(peak, 0.9, accuracy: 0.001)
    }

    func testMixAndNormalizeIgnoresEmptyTracks() {
        let a: [Float] = [0.2, -0.2]
        let mixed = AudioGain.mixAndNormalize([a, []], targetPeak: 0.8)
        XCTAssertEqual(mixed.count, 2)
    }

    func testMixAndNormalizeAllEmptyReturnsEmpty() {
        XCTAssertTrue(AudioGain.mixAndNormalize([[], []]).isEmpty)
    }
}
