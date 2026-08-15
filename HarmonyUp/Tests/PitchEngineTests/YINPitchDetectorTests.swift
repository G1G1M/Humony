import XCTest
@testable import HarmonyUp

final class YINPitchDetectorTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func sineWave(frequency: Double, sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    private func cents(detected: Double, expected: Double) -> Double {
        1200.0 * log2(detected / expected)
    }

    func testDetectsA4() throws {
        let samples = sineWave(frequency: 440.0, sampleCount: 2048)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(abs(cents(detected: candidate.frequency, expected: 440.0)), 0, accuracy: 10.0)
    }

    func testDetectsLowMaleVoiceFrequency() throws {
        // 남성 저음역대(약 110Hz, A2)를 커버하는지 확인 — 더 긴 버퍼가 필요하다.
        let samples = sineWave(frequency: 110.0, sampleCount: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(abs(cents(detected: candidate.frequency, expected: 110.0)), 0, accuracy: 10.0)
    }

    func testDetectsHigherFemaleVoiceFrequency() throws {
        let samples = sineWave(frequency: 880.0, sampleCount: 2048)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(abs(cents(detected: candidate.frequency, expected: 880.0)), 0, accuracy: 10.0)
    }

    func testSilenceReturnsNoCandidate() {
        let samples = [Float](repeating: 0, count: 2048)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testConfidenceIsHighForCleanTone() throws {
        let samples = sineWave(frequency: 440.0, sampleCount: 2048)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertGreaterThan(candidate.confidence, 0.9)
    }
}
