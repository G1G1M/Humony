import XCTest
@testable import HarmonyUp

final class ToneSynthesizerTests: XCTestCase {

    private let rate: Double = 44100

    func testSampleCountMatchesRequest() {
        let result = ToneSynthesizer.synthesize(frequency: 440, sampleCount: 1000, sampleRate: rate)
        XCTAssertEqual(result.count, 1000)
    }

    func testZeroOrNegativeSampleCountReturnsEmpty() {
        XCTAssertTrue(ToneSynthesizer.synthesize(frequency: 440, sampleCount: 0, sampleRate: rate).isEmpty)
        XCTAssertTrue(ToneSynthesizer.synthesize(frequency: 440, sampleCount: -5, sampleRate: rate).isEmpty)
    }

    func testNonPositiveFrequencyProducesSilence() {
        let result = ToneSynthesizer.synthesize(frequency: 0, sampleCount: 100, sampleRate: rate)
        XCTAssertEqual(result.count, 100)
        XCTAssertTrue(result.allSatisfy { $0 == 0 })
    }

    /// 배음(2배음×0.3 + 3배음×0.15)을 더한 뒤 /1.45로 정규화하므로, 클리핑(진폭이 1.0을
    /// 넘는 것) 없이 항상 -1...1 범위 안에 있어야 한다.
    func testAmplitudeStaysWithinUnitRange() {
        let result = ToneSynthesizer.synthesize(frequency: 220, sampleCount: 4410, sampleRate: rate)
        XCTAssertTrue(result.allSatisfy { $0 >= -1.0 && $0 <= 1.0 }, "정규화 후에도 진폭이 -1...1을 넘으면 클리핑 위험")
    }

    func testDifferentFrequenciesProduceDifferentWaveforms() {
        let low = ToneSynthesizer.synthesize(frequency: 220, sampleCount: 200, sampleRate: rate)
        let high = ToneSynthesizer.synthesize(frequency: 880, sampleCount: 200, sampleRate: rate)
        XCTAssertNotEqual(low, high)
    }
}
