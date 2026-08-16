import XCTest
@testable import HarmonyUp

final class PitchShifterTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func sineWave(frequency: Double, sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    private func middleSegment(of samples: [Float], length: Int) -> [Float] {
        guard samples.count > length else { return samples }
        let start = (samples.count - length) / 2
        return Array(samples[start..<(start + length)])
    }

    // PitchShifter를 검증하는 가장 확실한 방법은 이미 만들어둔 YINPitchDetector로
    // "실제로 원하는 주파수만큼 올라갔는지" 되짚어 재는 것이다 — 두 컴포넌트가 서로를 검증해준다.
    func testShiftUpByMajorThirdRaisesDetectedPitch() throws {
        let input = sineWave(frequency: 440.0, sampleCount: 8192)
        let ratio = pow(2.0, 4.0 / 12.0) // 장3도 위

        let shifted = PitchShifter.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)

        // 버퍼 맨 앞/끝은 오버랩-애드 경계에서 그레인이 충분히 안 겹쳐 진폭이 흔들리는 구간이라
        // (실제 재생에서는 짧은 페이드인/아웃처럼 들려 크게 문제되지 않지만) 피치 검증은 안정된
        // 가운데 구간으로 한다.
        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 440.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50) // WSOLA 특성상 정밀 검출보다는 여유를 둠
    }

    func testShiftDownByPerfectFifthLowersDetectedPitch() throws {
        let input = sineWave(frequency: 440.0, sampleCount: 8192)
        let ratio = pow(2.0, -7.0 / 12.0) // 완전5도 아래

        let shifted = PitchShifter.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)

        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 440.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    // 1단계(timeStretch)만 따로 검증 — 배속을 바꿔도(factor != 1) 피치 자체는 원래 그대로
    // 유지돼야 한다(길이만 바뀜). internal로 열어둔 이유가 이 테스트 때문이다.
    func testTimeStretchAlonePreservesPitchAtNonUnityFactor() throws {
        let input = sineWave(frequency: 440.0, sampleCount: 8192)
        let stretched = PitchShifter.timeStretch(samples: input, factor: 1.26)

        let middle = middleSegment(of: stretched, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(detected.frequency, 440.0, accuracy: 20)
    }

    // 2단계(resample)만 따로 검증 — rate만큼 피치가 정확히 올라가야 한다(리샘플링은 항상 정확함).
    func testResampleAloneShiftsPitchByRate() throws {
        let input = sineWave(frequency: 440.0, sampleCount: 8192)
        let resampled = PitchShifter.resample(samples: input, rate: 1.26)

        let middle = middleSegment(of: resampled, length: 2048)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(detected.frequency, 440.0 * 1.26, accuracy: 20)
    }

    func testIdentityRatioPreservesPitch() throws {
        let input = sineWave(frequency: 440.0, sampleCount: 8192)
        let shifted = PitchShifter.shift(samples: input, pitchRatio: 1.0, sampleRate: sampleRate)
        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(detected.frequency, 440.0, accuracy: 20)
    }

    func testOutputLengthApproximatelyMatchesInput() {
        let input = sineWave(frequency: 440.0, sampleCount: 8192)
        let shifted = PitchShifter.shift(samples: input, pitchRatio: 1.26, sampleRate: sampleRate)

        XCTAssertEqual(Double(shifted.count), Double(input.count), accuracy: 300)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(PitchShifter.shift(samples: [], pitchRatio: 1.5, sampleRate: sampleRate).isEmpty)
    }

    // 다운샘플링(rate > 1, 예: 3도/5도로 음을 높일 때) 전에 거는 저역통과 필터 — 나이퀴스트
    // 위 성분을 미리 줄여서 에일리어싱(접힘 잡음, "쇠소리" 같은 거슬리는 소리)을 완화한다.
    // 나이퀴스트에 가까운(가장 빠르게 진동하는) +1/-1 교대 신호는 크게 줄어들어야 하고,
    // 거의 안 변하는(직류에 가까운) 신호는 그대로 통과해야 한다 — 저역통과 필터의 기본 성질.
    func testAntiAliasFilterAttenuatesHighFrequencyMuchMoreThanLowFrequency() {
        let highFrequency: [Float] = (0..<1000).map { $0 % 2 == 0 ? 1.0 : -1.0 } // 나이퀴스트 신호
        let lowFrequency: [Float] = Array(repeating: 1.0, count: 1000) // 직류(0Hz)

        let filteredHigh = PitchShifter.antiAliasFilter(highFrequency, decimationRate: 4.0)
        let filteredLow = PitchShifter.antiAliasFilter(lowFrequency, decimationRate: 4.0)

        let highRMS = (filteredHigh.reduce(Float(0)) { $0 + $1 * $1 } / Float(filteredHigh.count)).squareRoot()
        let lowRMS = (filteredLow.reduce(Float(0)) { $0 + $1 * $1 } / Float(filteredLow.count)).squareRoot()

        XCTAssertLessThan(highRMS, 0.1)   // 거의 다 걸러짐
        XCTAssertEqual(lowRMS, 1.0, accuracy: 0.01) // 직류는 그대로 통과
    }

    func testAntiAliasFilterSkipsWhenNotDownsampling() {
        let samples: [Float] = [1, -1, 1, -1, 1]
        XCTAssertEqual(PitchShifter.antiAliasFilter(samples, decimationRate: 1.0), samples)
        XCTAssertEqual(PitchShifter.antiAliasFilter(samples, decimationRate: 0.5), samples)
    }

    // expectedFrequency를 넘겨도(탐색 반경이 좁아져도) 결과 피치 자체는 여전히 정확해야 한다 —
    // 회귀 방지용 테스트. (탐색 반경을 좁히는 게 프레임별 흔들림을 항상 줄여준다고 실측으로
    // 단정하긴 어려웠다 — 순음/유사음성 합성 신호로 여러 잡음 수준을 스윕해봤을 때 표준편차가
    // 오히려 커지는 경우도 있었다. 다만 원치 않는 먼 주기로 튀는 경우를 원천 차단한다는
    // 점에서 이론적으로는 여전히 안전망 역할을 하므로 파라미터 자체는 유지한다.)
    func testShiftWithExpectedFrequencyStillShiftsPitchCorrectly() throws {
        let input = sineWave(frequency: 220.0, sampleCount: 8192)
        let ratio = pow(2.0, 4.0 / 12.0) // 장3도 위

        let shifted = PitchShifter.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate, expectedFrequency: 220.0)

        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 220.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }
}
