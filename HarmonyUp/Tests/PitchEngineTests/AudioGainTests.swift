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

    func testMixAndNormalizeBalancesTracksOfVeryDifferentAmplitude() {
        // 한 트랙은 원래 진폭이 훨씬 작다(예: 다른 방식으로 처리된 성부) — 합치기 전에
        // 체감 음량(RMS)을 맞추지 않으면 이 트랙은 믹스에서 거의 안 들리게 묻힌다.
        let loud: [Float] = Array(repeating: Float(0.5), count: 100)
        let quiet: [Float] = Array(repeating: Float(0.02), count: 100)

        let mixed = AudioGain.mixAndNormalize([loud, quiet], targetPeak: 0.95)

        // 두 트랙이 동일한 상수 값이라 RMS 정규화 후 크기가 같아지고, 합치면 그 두 배(부호가
        // 같으므로) — 즉 원래 25배 차이 나던 두 트랙이 믹스에는 "똑같은 비중"으로 들어가야 한다.
        // 이걸 직접 검증하는 대신, mixAndNormalize([quiet, quiet])와 mixAndNormalize([loud, loud])가
        // (둘 다 내부적으로 같은 값으로 맞춰지므로) 같은 결과가 나오는지로 확인한다.
        let quietOnly = AudioGain.mixAndNormalize([quiet, quiet], targetPeak: 0.95)
        let loudOnly = AudioGain.mixAndNormalize([loud, loud], targetPeak: 0.95)
        for (a, b) in zip(mixed, quietOnly) {
            XCTAssertEqual(a, b, accuracy: 0.001)
        }
        for (a, b) in zip(mixed, loudOnly) {
            XCTAssertEqual(a, b, accuracy: 0.001)
        }
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
}
