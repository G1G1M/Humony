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

    // MARK: - 스테레오 팬 (145절)

    func testMixToStereoHardLeftPutsNothingInRightChannel() {
        let track = AudioGain.PannedTrack(samples: [0.5, 0.5, 0.5], pan: -1)
        let (left, right) = AudioGain.mixToStereo(tracks: [track])

        assertFloatArrayEqual(left, [0.5, 0.5, 0.5], accuracy: 0.0001)
        assertFloatArrayEqual(right, [0, 0, 0], accuracy: 0.0001)
    }

    func testMixToStereoHardRightPutsNothingInLeftChannel() {
        let track = AudioGain.PannedTrack(samples: [0.5, 0.5], pan: 1)
        let (left, right) = AudioGain.mixToStereo(tracks: [track])

        assertFloatArrayEqual(left, [0, 0], accuracy: 0.0001)
        assertFloatArrayEqual(right, [0.5, 0.5], accuracy: 0.0001)
    }

    // 등파워(equal-power) 팬 법칙의 핵심 — 정중앙에서 각 채널이 0.5가 아니라 1/√2(≈0.707)여야
    // 좌우로 옮겨도 체감 음량이 일정하다. 0.5씩 나누는 선형 팬은 중앙에서 에너지가 √2배
    // 작아져서 "가운데 성부만 뒤로 물러난" 것처럼 들린다.
    func testMixToStereoCenterUsesEqualPowerNotHalfGain() {
        let track = AudioGain.PannedTrack(samples: [1.0], pan: 0)
        let (left, right) = AudioGain.mixToStereo(tracks: [track])

        XCTAssertEqual(left[0], 0.7071, accuracy: 0.001)
        XCTAssertEqual(right[0], 0.7071, accuracy: 0.001)
    }

    func testMixToStereoSumsOverlappingTracksPerChannel() {
        let hardLeft = AudioGain.PannedTrack(samples: [0.2, 0.2], pan: -1)
        let hardRight = AudioGain.PannedTrack(samples: [0.3, 0.3], pan: 1)
        let (left, right) = AudioGain.mixToStereo(tracks: [hardLeft, hardRight])

        assertFloatArrayEqual(left, [0.2, 0.2], accuracy: 0.0001)
        assertFloatArrayEqual(right, [0.3, 0.3], accuracy: 0.0001)
    }

    func testMixToStereoLengthMatchesLongestTrack() {
        let long = AudioGain.PannedTrack(samples: [0.1, 0.1, 0.1, 0.1], pan: 0)
        let short = AudioGain.PannedTrack(samples: [0.1], pan: 0)
        let (left, right) = AudioGain.mixToStereo(tracks: [long, short])

        XCTAssertEqual(left.count, 4)
        XCTAssertEqual(right.count, 4)
    }

    func testMixToStereoEmptyInputReturnsEmptyChannels() {
        let (left, right) = AudioGain.mixToStereo(tracks: [])
        XCTAssertEqual(left, [])
        XCTAssertEqual(right, [])
    }

    // 스테레오 정규화에서 제일 중요한 불변식 — 채널마다 따로 게인을 재면 한쪽만 커져서
    // 정위(定位)가 통째로 밀린다. 두 채널에 **같은** 게인이 걸려야 한다.
    func testNormalizeStereoAppliesIdenticalGainToBothChannels() {
        // 왼쪽이 오른쪽보다 4배 큰 상태 — 정규화 후에도 그 비율이 유지돼야 한다.
        let left: [Float] = (0..<1000).map { Float(0.4 * sin(2.0 * Double.pi * 10.0 * Double($0) / 1000.0)) }
        let right = left.map { $0 * 0.25 }

        let (outLeft, outRight) = AudioGain.normalizeStereo(left: left, right: right, targetRMS: 0.25, peakCeiling: 0.98)

        for (l, r) in zip(outLeft, outRight) where abs(l) > 0.0001 {
            XCTAssertEqual(r / l, 0.25, accuracy: 0.001)
        }
    }

    func testNormalizeStereoClampsCombinedPeakToCeiling() {
        var left = [Float](repeating: 0.02, count: 1000)
        left[500] = 0.9
        let right = [Float](repeating: 0.02, count: 1000)

        let (outLeft, outRight) = AudioGain.normalizeStereo(left: left, right: right, targetRMS: 0.25, peakCeiling: 0.7)

        let peak = max(outLeft.map { abs($0) }.max() ?? 0, outRight.map { abs($0) }.max() ?? 0)
        XCTAssertLessThanOrEqual(peak, 0.7 + 0.001)
    }

    func testNormalizeStereoSilentInputReturnsUnchanged() {
        let silence = [Float](repeating: 0, count: 10)
        let (left, right) = AudioGain.normalizeStereo(left: silence, right: silence)
        XCTAssertEqual(left, silence)
        XCTAssertEqual(right, silence)
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
