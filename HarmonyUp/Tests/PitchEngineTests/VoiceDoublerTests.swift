import XCTest
@testable import HarmonyUp

final class VoiceDoublerTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func voiceLikeWave(frequency: Double, sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { i in
            var value = 0.0
            for harmonic in 1...8 {
                value += sin(2.0 * Double.pi * frequency * Double(harmonic) * Double(i) / sampleRate) / Double(harmonic)
            }
            return Float(value)
        }
    }

    func testOutputLengthMatchesInput() {
        let input = voiceLikeWave(frequency: 220.0, sampleCount: 8192)
        let result = VoiceDoubler.double(samples: input, sampleRate: sampleRate, delayMilliseconds: 20, detuneCents: 6)
        XCTAssertEqual(result.count, input.count)
    }

    // 지연 구간(예: 20ms ≈ 882샘플) 안에서는 아직 복사본이 도착하지 않았으므로, 그 구간은
    // 원본과 정확히 같아야 한다 — 더블링이 "지연된 복사본을 더한다"는 계약을 정확히 지키는지
    // 확인하는 가장 직접적인 방법이다.
    func testLeadingSamplesWithinDelayWindowRemainUnchanged() {
        let input = voiceLikeWave(frequency: 220.0, sampleCount: 8192)
        let delayMS = 20.0
        let result = VoiceDoubler.double(samples: input, sampleRate: sampleRate, delayMilliseconds: delayMS, detuneCents: 6)

        let delaySampleCount = Int(sampleRate * delayMS / 1000.0)
        for i in 0..<delaySampleCount {
            XCTAssertEqual(result[i], input[i], accuracy: 0.0001)
        }
    }

    // 지연 구간이 지난 뒤에는 디튠된 복사본이 더해지므로 원본과 달라져야 한다 — 아무 효과도
    // 안 걸리는 채로 조용히 통과하는 회귀를 잡는다.
    func testSamplesAfterDelayWindowDifferFromInput() {
        let input = voiceLikeWave(frequency: 220.0, sampleCount: 8192)
        let delayMS = 20.0
        let result = VoiceDoubler.double(samples: input, sampleRate: sampleRate, delayMilliseconds: delayMS, detuneCents: 6)

        let delaySampleCount = Int(sampleRate * delayMS / 1000.0)
        var foundDifference = false
        for i in (delaySampleCount + 100)..<8192 {
            if abs(result[i] - input[i]) > 0.001 {
                foundDifference = true
                break
            }
        }
        XCTAssertTrue(foundDifference)
    }

    func testMixLevelZeroReturnsInputUnchanged() {
        let input = voiceLikeWave(frequency: 220.0, sampleCount: 4096)
        let result = VoiceDoubler.double(samples: input, sampleRate: sampleRate, delayMilliseconds: 20, detuneCents: 6, mixLevel: 0)
        XCTAssertEqual(result, input)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(VoiceDoubler.double(samples: [], sampleRate: sampleRate, delayMilliseconds: 20, detuneCents: 6).isEmpty)
    }

    func testZeroDelayReturnsInputUnchanged() {
        let input = voiceLikeWave(frequency: 220.0, sampleCount: 4096)
        XCTAssertEqual(VoiceDoubler.double(samples: input, sampleRate: sampleRate, delayMilliseconds: 0, detuneCents: 6), input)
    }

    // 성부(베이스/3도/5도)마다 지연/디튠 값이 달라야 한다는 설계 결정을 그대로 확인한다 —
    // 실수로 세 성부가 같은 파라미터를 쓰게 되면(더블링 효과가 "다 같이 출렁여서" 오히려
    // 인공적으로 들리는 회귀) 이 테스트가 잡아준다.
    func testEachIntervalProducesDistinctResult() {
        let input = voiceLikeWave(frequency: 220.0, sampleCount: 8192)
        let bass = VoiceDoubler.apply(to: input, sampleRate: sampleRate, interval: .bass)
        let third = VoiceDoubler.apply(to: input, sampleRate: sampleRate, interval: .third)
        let fifth = VoiceDoubler.apply(to: input, sampleRate: sampleRate, interval: .fifth)

        XCTAssertNotEqual(bass, third)
        XCTAssertNotEqual(third, fifth)
        XCTAssertNotEqual(bass, fifth)
    }
}
