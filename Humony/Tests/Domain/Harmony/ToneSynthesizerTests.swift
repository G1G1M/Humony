import XCTest
@testable import Humony

final class ToneSynthesizerTests: XCTestCase {

    func testSynthesizeProducesRequestedSampleCount() {
        let samples = ToneSynthesizer.synthesize(frequency: 440, sampleCount: 1000, sampleRate: 44100)
        XCTAssertEqual(samples.count, 1000)
    }

    func testSynthesizeProducesCorrectFrequencyViaZeroCrossings() {
        // 440Hz를 44100Hz로 1초(44100샘플) 합성하면 사인파가 정확히 440번 진동한다 —
        // 위→아래 방향 영교차 횟수를 세면 주파수를 직접 검증할 수 있다.
        let sampleRate = 44100.0
        let samples = ToneSynthesizer.synthesize(frequency: 440, sampleCount: Int(sampleRate), sampleRate: sampleRate)

        var descendingCrossings = 0
        for i in 1..<samples.count {
            if samples[i - 1] >= 0, samples[i] < 0 { descendingCrossings += 1 }
        }
        XCTAssertEqual(descendingCrossings, 440, accuracy: 1)
    }

    func testSynthesizeWithZeroOrNegativeFrequencyReturnsSilence() {
        let samples = ToneSynthesizer.synthesize(frequency: 0, sampleCount: 100, sampleRate: 44100)
        XCTAssertEqual(samples, [Float](repeating: 0, count: 100))
    }

    func testSynthesizeWithNonPositiveSampleCountReturnsEmpty() {
        XCTAssertEqual(ToneSynthesizer.synthesize(frequency: 440, sampleCount: 0, sampleRate: 44100), [])
        XCTAssertEqual(ToneSynthesizer.synthesize(frequency: 440, sampleCount: -5, sampleRate: 44100), [])
    }

    func testSynthesizeStaysWithinUnitAmplitude() {
        let samples = ToneSynthesizer.synthesize(frequency: 300, sampleCount: 5000, sampleRate: 44100)
        for sample in samples {
            XCTAssertLessThanOrEqual(abs(sample), 1.0001)
        }
    }
}
