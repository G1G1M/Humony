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

    func testApplyFadeInOutStartsAndEndsAtZero() {
        let samples: [Float] = Array(repeating: 1.0, count: 100)
        let faded = AudioGain.applyFadeInOut(samples, fadeSampleCount: 10)

        XCTAssertEqual(faded[0], 0, accuracy: 0.0001)
        XCTAssertEqual(faded[faded.count - 1], 0, accuracy: 0.0001)
        // 페이드 구간 밖(가운데)은 원본 그대로 유지돼야 한다.
        XCTAssertEqual(faded[50], 1.0, accuracy: 0.0001)
    }

    func testApplyFadeInOutRampIsLinear() {
        let samples: [Float] = Array(repeating: 1.0, count: 100)
        let faded = AudioGain.applyFadeInOut(samples, fadeSampleCount: 10)

        XCTAssertEqual(faded[5], 0.5, accuracy: 0.01)
    }

    func testApplyFadeInOutOnBufferShorterThanFadeSplitsInHalf() {
        // 페이드 구간(10)이 버퍼 절반(3)보다 길면, 전체가 무음이 되지 않도록 절반씩만 적용한다.
        let samples: [Float] = Array(repeating: 1.0, count: 6)
        let faded = AudioGain.applyFadeInOut(samples, fadeSampleCount: 10)

        XCTAssertEqual(faded.count, samples.count)
        XCTAssertFalse(faded.allSatisfy { $0 == 0 })
    }

    func testApplyFadeInOutOnEmptyBufferReturnsEmpty() {
        XCTAssertTrue(AudioGain.applyFadeInOut([], fadeSampleCount: 10).isEmpty)
    }

    func testApplyGainScalesEverySampleByFactor() {
        let samples: [Float] = [0.2, -0.4, 0.6]
        let gained = AudioGain.applyGain(samples, factor: 0.85)
        let expected: [Float] = [0.17, -0.34, 0.51]

        XCTAssertEqual(gained.count, expected.count)
        for (actual, expectedValue) in zip(gained, expected) {
            XCTAssertEqual(actual, expectedValue, accuracy: 0.001)
        }
    }

    func testApplyGainOnEmptyBufferReturnsEmpty() {
        XCTAssertTrue(AudioGain.applyGain([], factor: 0.85).isEmpty)
    }

    func testMixToStereoCenterPanSplitsEquallyWithEqualPowerGain() {
        let mixed = AudioGain.mixToStereo(tracks: [(samples: [1.0, 1.0], pan: 0.0)])
        // 등에너지 팬 법칙에서 pan=0(가운데)일 때 좌우 게인은 각각 1/√2 ≈ 0.707.
        XCTAssertEqual(mixed.left, mixed.right)
        XCTAssertEqual(mixed.left[0], Float(1.0 / 2.0.squareRoot()), accuracy: 0.001)
    }

    func testMixToStereoFullLeftPanSilencesRightChannel() {
        let mixed = AudioGain.mixToStereo(tracks: [(samples: [1.0, 0.5], pan: -1.0)])
        XCTAssertEqual(mixed.left, [1.0, 0.5])
        XCTAssertEqual(mixed.right[0], 0, accuracy: 0.0001)
    }

    func testMixToStereoSumsMultipleTracksSampleAligned() {
        // 두 트랙이 같은 인덱스에서 정확히 더해져야 한다(밀림 없이 재생되는 이유의 핵심).
        let mixed = AudioGain.mixToStereo(tracks: [
            (samples: [1.0, 0.0], pan: 0.0),
            (samples: [0.0, 1.0], pan: 0.0)
        ])
        let unit = Float(1.0 / 2.0.squareRoot())
        XCTAssertEqual(mixed.left[0], unit, accuracy: 0.001)
        XCTAssertEqual(mixed.left[1], unit, accuracy: 0.001)
    }

    func testMixToStereoPadsShorterTrackWithZeroInsteadOfShrinkingOutput() {
        let mixed = AudioGain.mixToStereo(tracks: [
            (samples: [1.0, 1.0, 1.0], pan: 0.0),
            (samples: [1.0], pan: 0.0)
        ])
        XCTAssertEqual(mixed.left.count, 3)
        XCTAssertEqual(mixed.right.count, 3)
    }

    func testMixToStereoEmptyTracksReturnsEmpty() {
        let mixed = AudioGain.mixToStereo(tracks: [])
        XCTAssertTrue(mixed.left.isEmpty)
        XCTAssertTrue(mixed.right.isEmpty)
    }
}
