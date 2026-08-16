import XCTest
@testable import HarmonyUp

final class VoiceSegmentTrimmerTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func sineWave(frequency: Double, duration: Double) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    private func detectedFrequency(_ samples: [Float]) -> Double? {
        YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate).first?.frequency
    }

    // 앞쪽엔 다른 음(220Hz), 뒤쪽엔 목표음(440Hz)이 이어붙어 있는 버퍼 — 목표음 구간만 남아야 한다.
    func testTrimRemovesLeadingDifferentPitch() throws {
        let previousNote = sineWave(frequency: 220.0, duration: 0.8)
        let targetNote = sineWave(frequency: 440.0, duration: 0.8)
        let buffer = previousNote + targetNote

        let trimmed = VoiceSegmentTrimmer.trimToStableSegment(
            samples: buffer, sampleRate: sampleRate, targetFrequency: 440.0
        )

        // 잘려나간 뒤 남은 길이가 원본 목표음 구간(0.8초) 근처여야 한다 — 이전 음(0.8초)이
        // 대부분 잘려나갔는지 확인.
        XCTAssertLessThan(trimmed.count, buffer.count)
        XCTAssertEqual(Double(trimmed.count) / sampleRate, 0.8, accuracy: 0.15)

        let frequency = try XCTUnwrap(detectedFrequency(Array(trimmed.suffix(4096))))
        XCTAssertEqual(frequency, 440.0, accuracy: 5)
    }

    // 버퍼 전체가 목표음 하나로만 이루어져 있으면 거의 그대로(잘라도 손실이 미미) 유지돼야 한다.
    func testTrimKeepsMostOfBufferWhenAllStable() {
        let buffer = sineWave(frequency: 440.0, duration: 1.0)

        let trimmed = VoiceSegmentTrimmer.trimToStableSegment(
            samples: buffer, sampleRate: sampleRate, targetFrequency: 440.0
        )

        XCTAssertEqual(Double(trimmed.count) / sampleRate, 1.0, accuracy: 0.1)
    }

    // 버퍼 전체가 목표음과 전혀 다른 음이면 자를 안정 구간이 없으므로 원본을 그대로 반환한다
    // (화음이 아예 안 나오는 것보단, 예전처럼 통째로라도 들리는 게 안전한 폴백).
    func testTrimFallsBackToOriginalWhenNoStableSegmentFound() {
        let buffer = sineWave(frequency: 220.0, duration: 1.0)

        let trimmed = VoiceSegmentTrimmer.trimToStableSegment(
            samples: buffer, sampleRate: sampleRate, targetFrequency: 440.0
        )

        XCTAssertEqual(trimmed, buffer)
    }

    // 분석 윈도우(1024샘플) 하나가 안 나올 만큼 버퍼가 짧으면 그대로 반환한다.
    func testTrimReturnsOriginalWhenBufferShorterThanWindow() {
        let buffer: [Float] = Array(repeating: 0.1, count: 500)

        let trimmed = VoiceSegmentTrimmer.trimToStableSegment(
            samples: buffer, sampleRate: sampleRate, targetFrequency: 440.0
        )

        XCTAssertEqual(trimmed, buffer)
    }

    func testTrimReturnsOriginalWhenTargetFrequencyIsZero() {
        let buffer = sineWave(frequency: 440.0, duration: 1.0)

        let trimmed = VoiceSegmentTrimmer.trimToStableSegment(
            samples: buffer, sampleRate: sampleRate, targetFrequency: 0
        )

        XCTAssertEqual(trimmed, buffer)
    }
}
