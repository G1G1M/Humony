import XCTest
@testable import HarmonyUp

final class VoiceActivityDetectorTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func sineWave(frequency: Double, amplitude: Float, sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { i in
            amplitude * Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    func testSilenceIsNotActive() {
        let samples = [Float](repeating: 0, count: 2048)
        XCTAssertFalse(VoiceActivityDetector.isVoiceActive(samples: samples))
    }

    func testLoudToneIsActive() {
        let samples = sineWave(frequency: 440.0, amplitude: 0.5, sampleCount: 2048)
        XCTAssertTrue(VoiceActivityDetector.isVoiceActive(samples: samples))
    }

    func testVeryQuietNoiseIsNotActive() {
        // 배경 소음 수준(작은 진폭)의 사인파 — 임계값 아래라 음성으로 판정되면 안 된다.
        let samples = sineWave(frequency: 440.0, amplitude: 0.001, sampleCount: 2048)
        XCTAssertFalse(VoiceActivityDetector.isVoiceActive(samples: samples))
    }

    func testEmptySamplesIsNotActive() {
        XCTAssertFalse(VoiceActivityDetector.isVoiceActive(samples: []))
    }

    func testCustomThresholdIsRespected() {
        let samples = sineWave(frequency: 440.0, amplitude: 0.5, sampleCount: 2048)
        var config = VoiceActivityDetector.Configuration.default
        config.energyThreshold = 1.0 // 사인파 진폭 0.5의 평균 파워(0.125)보다 훨씬 높게 설정
        XCTAssertFalse(VoiceActivityDetector.isVoiceActive(samples: samples, configuration: config))
    }
}
