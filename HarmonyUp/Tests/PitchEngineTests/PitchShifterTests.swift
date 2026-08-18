import XCTest
@testable import HarmonyUp

final class PitchShifterTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    /// 배음이 풍부한 합성 신호(처음 8개 배음을 1/n 진폭으로 더한 톱니파에 가까운 파형) —
    /// 사람 목소리의 성문(글로티스) 파형처럼 배음이 풍부한 신호를 흉내낸다. 순음(사인파)이
    /// 아니라 이걸 쓰는 이유: WORLD 이전에 직접 구현했던 PSOLA 버전(47절)에서, 순음은
    /// 배음이 없어 겹쳐 더한 그레인들이 선형 중첩 원리상 원래 주파수로 되돌아가는 문제가
    /// 있었다 — 실제 목소리를 흉내낸 신호로 검증하는 습관을 그대로 유지한다.
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

    // PitchShifter를 검증하는 가장 확실한 방법은 이미 만들어둔 YINPitchDetector로
    // "실제로 원하는 주파수만큼 올라갔는지" 되짚어 재는 것이다 — 두 컴포넌트가 서로를 검증해준다.
    // (v3, 48절: 내부를 직접 구현한 PSOLA에서 WORLD로 바꿨지만, 이 공개 계약
    // "shift(pitchRatio:)를 걸면 그만큼 피치가 바뀐다"는 그대로 유지돼야 한다.)
    func testShiftUpByMajorThirdRaisesDetectedPitch() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let ratio = pow(2.0, 4.0 / 12.0) // 장3도 위

        let shifted = PitchShifter.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)
        XCTAssertEqual(shifted.count, input.count)

        // 버퍼 맨 앞/끝은 WORLD의 프레임 경계 처리 특성상 불안정할 수 있어서 안정된
        // 가운데 구간으로 검증한다.
        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 440.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    func testShiftDownByPerfectFifthLowersDetectedPitch() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let ratio = pow(2.0, -7.0 / 12.0) // 완전5도 아래

        let shifted = PitchShifter.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)

        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 440.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    func testShiftDownByOctaveLowersDetectedPitch() throws {
        // 베이스 성부(1옥타브 아래, pitchRatio=0.5)는 지금까지 테스트한 것 중 가장 큰
        // 비율 변화라 별도로 검증한다 — 47절에서 직접 구현한 PSOLA가 가장 애먹었던 케이스.
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let ratio = 0.5

        let shifted = PitchShifter.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)

        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 440.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    func testIdentityRatioPreservesPitch() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let shifted = PitchShifter.shift(samples: input, pitchRatio: 1.0, sampleRate: sampleRate)
        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(detected.frequency, 440.0, accuracy: 20)
    }

    func testOutputLengthMatchesInput() {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)
        let shifted = PitchShifter.shift(samples: input, pitchRatio: 1.26, sampleRate: sampleRate)
        XCTAssertEqual(shifted.count, input.count)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(PitchShifter.shift(samples: [], pitchRatio: 1.5, sampleRate: sampleRate).isEmpty)
    }

    func testInvalidPitchRatioReturnsInputUnchanged() {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 4096)
        XCTAssertEqual(PitchShifter.shift(samples: input, pitchRatio: 0, sampleRate: sampleRate), input)
        XCTAssertEqual(PitchShifter.shift(samples: input, pitchRatio: -1, sampleRate: sampleRate), input)
    }

    // formantRatio를 안 넘기면 예전 호출부(포먼트 개념이 없던 시절)와 완전히 같은 경로를
    // 타야 한다 — 브릿지 쪽에서 formantRatio == 1.0이면 워핑 자체를 건너뛰므로, 기본값을
    // 안 쓴 명시적 1.0 호출과 바이트 단위로 같은 결과가 나와야 한다(Phase 8 Task 1).
    func testFormantRatioDefaultMatchesExplicitIdentity() {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 8192)
        let ratio = pow(2.0, -7.0 / 12.0)

        let withDefault = PitchShifter.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)
        let withExplicitIdentity = PitchShifter.shift(samples: input, pitchRatio: ratio, formantRatio: 1.0, sampleRate: sampleRate)

        XCTAssertEqual(withDefault, withExplicitIdentity)
    }

    // 포먼트(스펙트럼 포락선)와 F0(피치)는 WORLD 안에서 서로 독립적인 축이다 — pitchRatio를
    // 1.0으로 고정한 채 formantRatio만 바꿔도, YIN으로 되짚어 재는 F0 자체는 그대로 440Hz
    // 근처여야 한다(포먼트만 바뀌고 피치는 안 바뀌는지 확인).
    func testFormantRatioDoesNotChangeDetectedPitch() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 16384)

        let shifted = PitchShifter.shift(samples: input, pitchRatio: 1.0, formantRatio: 1.15, sampleRate: sampleRate)
        XCTAssertEqual(shifted.count, input.count)

        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let cents = 1200.0 * log2(detected.frequency / 440.0)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    // WORLD은 순수 Swift 구현보다 훨씬 무겁다(F0 추정+스펙트럼 포락선+비주기성 분석을 전부
    // 거친다) — "빠른 녹음"의 녹음 상한(30초, PracticeView.quickRecordMaxDuration)에 맞춰
    // 실측해두고, 나중에 알고리즘을 더 바꿨을 때 눈에 띄게 느려지면(예: 실수로 Dio 대신
    // Harvest로 되돌아가는 등) 이 테스트가 잡아준다. 시뮬레이터 기준 30초 클립에 Dio+
    // StoneMask 조합으로 약 3.5초 걸렸다(Harvest 단독으로는 약 5초) — 여유를 넉넉히 두고
    // 10초를 상한으로 잡는다("전체 화음" 버튼은 성부 3개를 순서대로 처리하므로 체감은 더
    // 길다는 점을 감안해도, 이미 백그라운드 Task+"만드는 중…" 상태 표시로 처리 중임을
    // 알려주고 있어 UI가 멈추진 않는다).
    func testPerformanceStaysWithinBudgetFor30SecondClip() {
        let count = Int(44100.0 * 30)
        let input: [Float] = (0..<count).map { i in
            var value = 0.0
            for harmonic in 1...8 {
                value += sin(2.0 * Double.pi * 220.0 * Double(harmonic) * Double(i) / 44100.0) / Double(harmonic)
            }
            return Float(value)
        }

        let start = Date()
        _ = PitchShifter.shift(samples: input, pitchRatio: 1.5, sampleRate: 44100.0)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 10.0)
    }
}
