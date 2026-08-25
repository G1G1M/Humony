import XCTest
@testable import Humony

/// `PitchShifterWorldAnalysis`(129절, "전체 한 번 분석 + F0곡선 재합성" 구조의 1단계)를
/// 검증한다. 핵심 확인 사항 두 가지: (1) 이 handle 기반 경로가 기존
/// `PitchShifterWorld.shift`(내부적으로 이제 이 API의 얇은 래퍼)와 완전히 같은 결과를
/// 내는지, (2) 분석 하나를 재사용해서 F0 곡선의 "구간마다 다른 비율"을 적용해도 각 구간이
/// 의도한 피치로 정확히 재합성되는지 — 이게 다음 단계(`VoiceHarmonyTrackBuilder` 재작성)가
/// 기댈 핵심 능력이다(세그먼트를 잘라 따로 분석하지 않고, 한 번 분석한 F0 곡선의 구간별
/// 값만 바꿔서 화음 성부를 만든다).
final class PitchShifterWorldAnalysisTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    /// `PitchShifterWorldTests`와 같은 이유로 순음 대신 배음이 풍부한 신호를 쓴다
    /// (사람 목소리의 성문 파형을 흉내냄, 순음은 겹쳐 더한 그레인이 원래 주파수로
    /// 되돌아가는 특성이 있어 검증에 부적합했던 전례가 있다).
    private func voiceLikeWave(frequency: Double, sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { i in
            var value = 0.0
            for harmonic in 1...8 {
                value += sin(2.0 * Double.pi * frequency * Double(harmonic) * Double(i) / sampleRate) / Double(harmonic)
            }
            return Float(value)
        }
    }

    private func middleSegment(of samples: [Float], length: Int) -> [Float] {
        guard samples.count > length else { return samples }
        let start = (samples.count - length) / 2
        return Array(samples[start..<(start + length)])
    }

    private func detectedFrequency(_ samples: [Float]) throws -> Double {
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)
        return try XCTUnwrap(candidates.first).frequency
    }

    // MARK: - 분석 결과 자체가 말이 되는지

    func testAnalysisExposesConsistentMetadata() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let analysis = try XCTUnwrap(PitchShifterWorldAnalysis(samples: input, sampleRate: sampleRate))

        XCTAssertEqual(analysis.inputLength, input.count)
        XCTAssertEqual(analysis.framePeriodMs, 5.0)
        XCTAssertGreaterThan(analysis.f0Length, 0)
        XCTAssertEqual(analysis.f0.count, analysis.f0Length)

        // 440Hz 정상음 구간에서는 원본 F0 곡선의 유성음 프레임 대부분이 440Hz 근처여야 한다.
        let voicedFrames = analysis.f0.filter { $0 > 0 }
        XCTAssertFalse(voicedFrames.isEmpty)
        let averageVoiced = voicedFrames.reduce(0, +) / Double(voicedFrames.count)
        let cents = 1200.0 * log2(averageVoiced / 440.0)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    func testEmptyInputFailsToInitialize() {
        XCTAssertNil(PitchShifterWorldAnalysis(samples: [], sampleRate: sampleRate))
    }

    // MARK: - 기존 PitchShifterWorld.shift와 동등성

    // HumonyWorldPitchShift(옛 단일 함수)가 이제 내부적으로 Analyze+SynthesizeWithF0로
    // 구현되어 있으므로, 여기서 같은 절차를 Swift 쪽에서 직접 밟아도 바이트 단위로 같은
    // 결과가 나와야 한다 — 구조를 바꿨을 뿐 동작은 하나도 안 바뀌었음을 보장하는 회귀 테스트.
    func testAnalyzeThenUniformSynthesizeMatchesOldShiftFunction() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let ratio = pow(2.0, 4.0 / 12.0) // 장3도 위

        let viaOldPath = PitchShifterWorld.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)

        let analysis = try XCTUnwrap(PitchShifterWorldAnalysis(samples: input, sampleRate: sampleRate))
        let modifiedF0 = analysis.f0.map { $0 > 0 ? $0 * ratio : 0 }
        let viaNewPath = analysis.synthesize(f0: modifiedF0)

        XCTAssertEqual(viaOldPath, viaNewPath)
    }

    func testAnalyzeThenUniformSynthesizeMatchesOldShiftFunctionWithFormantRatio() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let ratio = pow(2.0, -7.0 / 12.0) // 완전5도 아래
        let formantRatio = 0.95

        let viaOldPath = PitchShifterWorld.shift(samples: input, pitchRatio: ratio, formantRatio: formantRatio, sampleRate: sampleRate)

        let analysis = try XCTUnwrap(PitchShifterWorldAnalysis(samples: input, sampleRate: sampleRate))
        let modifiedF0 = analysis.f0.map { $0 > 0 ? $0 * ratio : 0 }
        let viaNewPath = analysis.synthesize(f0: modifiedF0, formantRatio: formantRatio)

        XCTAssertEqual(viaOldPath, viaNewPath)
    }

    // MARK: - 분석 하나를 재사용해서 여러 성부 만들기

    // 다음 단계(VoiceHarmonyTrackBuilder 재작성)가 기댈 핵심 시나리오: 같은 분석 handle로
    // synthesize를 두 번(성부마다 한 번씩) 불러도 각각 의도한 비율로 정확히 재합성되는지.
    func testSameAnalysisReusedForTwoDifferentRatiosProducesIndependentPitches() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let thirdRatio = pow(2.0, 4.0 / 12.0)
        let fifthRatio = pow(2.0, 7.0 / 12.0)

        let analysis = try XCTUnwrap(PitchShifterWorldAnalysis(samples: input, sampleRate: sampleRate))

        let thirdF0 = analysis.f0.map { $0 > 0 ? $0 * thirdRatio : 0 }
        let fifthF0 = analysis.f0.map { $0 > 0 ? $0 * fifthRatio : 0 }

        let thirdOutput = analysis.synthesize(f0: thirdF0)
        let fifthOutput = analysis.synthesize(f0: fifthF0)

        let thirdDetected = try detectedFrequency(middleSegment(of: thirdOutput, length: 4096))
        let fifthDetected = try detectedFrequency(middleSegment(of: fifthOutput, length: 4096))

        XCTAssertEqual(1200.0 * log2(thirdDetected / (440.0 * thirdRatio)), 0, accuracy: 50)
        XCTAssertEqual(1200.0 * log2(fifthDetected / (440.0 * fifthRatio)), 0, accuracy: 50)
    }

    // MARK: - 구간별로 다른 비율을 적용한 F0 곡선 (핵심 능력)

    // 목소리 전체를 한 번만 분석한 뒤, F0 곡선의 앞쪽 절반은 원본 그대로 두고 뒤쪽 절반만
    // 장3도 위로 옮겨서 재합성한다 — "한 곡선 안에서 구간마다 다른 화음 음정"이 실제로
    // 가능한지 확인하는 테스트. 두 정상음 구간(220Hz→440Hz 글리산도의 앞/뒤와 달리, 여기선
    // 같은 음이 이어지다가 중간에 화음으로 바뀌는 상황을 흉내냄)에서 각각 올바른 주파수가
    // 검출돼야 한다.
    func testSynthesizeWithRegionVaryingF0AppliesRatioOnlyToThatRegion() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let ratio = pow(2.0, 4.0 / 12.0) // 장3도 위

        let analysis = try XCTUnwrap(PitchShifterWorldAnalysis(samples: input, sampleRate: sampleRate))
        let half = analysis.f0Length / 2

        let regionVaryingF0 = analysis.f0.enumerated().map { index, original -> Double in
            guard original > 0 else { return 0 }
            return index < half ? original : original * ratio
        }

        let output = analysis.synthesize(f0: regionVaryingF0)
        XCTAssertEqual(output.count, input.count)

        // 프레임 인덱스 -> 샘플 인덱스로 변환해 앞/뒤 구간에서 안정된 가운데 부분만 뽑는다.
        let rate = sampleRate
        let framesToSamples = { (frameIndex: Int) -> Int in
            Int(Double(frameIndex) * analysis.framePeriodMs / 1000.0 * rate)
        }
        let firstRegionEnd = framesToSamples(half)
        let firstRegion = Array(output[0..<firstRegionEnd])
        let secondRegion = Array(output[firstRegionEnd...])

        let firstDetected = try detectedFrequency(middleSegment(of: firstRegion, length: 4096))
        let secondDetected = try detectedFrequency(middleSegment(of: secondRegion, length: 4096))

        XCTAssertEqual(1200.0 * log2(firstDetected / 440.0), 0, accuracy: 50)
        XCTAssertEqual(1200.0 * log2(secondDetected / (440.0 * ratio)), 0, accuracy: 50)
    }

    func testSynthesizeOutputLengthMatchesInputLength() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let analysis = try XCTUnwrap(PitchShifterWorldAnalysis(samples: input, sampleRate: sampleRate))
        let output = analysis.synthesize(f0: analysis.f0)
        XCTAssertEqual(output.count, input.count)
    }
}
