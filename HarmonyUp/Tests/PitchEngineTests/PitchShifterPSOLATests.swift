import XCTest
@testable import HarmonyUp

/// `PitchShifterPSOLA`(2026-08-20에 `c94288b`에서 복원)의 테스트 — 당시 WORLD로
/// 교체되기 직전 버전의 테스트를 그대로 가져왔다(파일명만 조정).
final class PitchShifterPSOLATests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func sineWave(frequency: Double, sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    /// 배음이 풍부한 합성 신호(처음 8개 배음을 1/n 진폭으로 더한 톱니파에 가까운 파형) —
    /// 사람 목소리의 성문(글로티스) 파형처럼 배음이 풍부한 신호를 흉내낸다. 순음(사인파)과
    /// 달리 이게 필요한 이유가 있다 — 아래 `testShiftDownByOctaveLowersDetectedPitch` 주석 참고.
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

    // 순음(사인파) 대신 `voiceLikeWave`(배음 있는 신호)를 쓰는 이유: 순음은 이 알고리즘에는
    // 수학적으로 부적절한 시험 신호였다 — 겹쳐 더한 그레인이 전부 "같은 순음의 이동한 조각"일
    // 뿐이라, 중첩(superposition)만으로는 새 주파수의 순음이 나올 수 없는 경우가 실제로
    // 있었다(특히 피치를 크게 낮출 때, 유닛테스트로 발견). 목소리는 배음이 풍부해서 이 문제가
    // 훨씬 덜하고, 실제 사용 대상(목소리)에도 더 가깝다.
    func testShiftUpByMajorThirdRaisesDetectedPitch() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 8192)
        let ratio = pow(2.0, 4.0 / 12.0) // 장3도 위

        let shifted = PitchShifterPSOLA.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)

        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 440.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50) // 그레인 배치 특성상 정밀 검출보다는 여유를 둠
    }

    func testShiftDownByPerfectFifthLowersDetectedPitch() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 8192)
        let ratio = pow(2.0, -7.0 / 12.0) // 완전5도 아래

        let shifted = PitchShifterPSOLA.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)

        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 440.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    func testShiftDownByOctaveLowersDetectedPitch() throws {
        // 베이스 성부(1옥타브 아래, pitchRatio=0.5)는 지금까지 테스트한 것 중 가장 큰 비율
        // 변화라 별도로 검증한다. 이 케이스에서 순음 입력으로는 절대 피치가 안 바뀌는 걸
        // 발견했다 — 순음은 배음이 없어서, 겹쳐 더한 그레인들이 전부 "같은 순음의 이동한
        // 조각"일 뿐이라 중첩 원리상 원래 주파수의 순음으로 되돌아갈 수밖에 없었다(그레인을
        // 아무리 다시 배치해도). 배음이 있는 신호(`voiceLikeWave`)로 바꾸니 정확히 shift됨을
        // 확인했다 — 실제 목소리는 원래 배음이 풍부해서 이 문제를 겪지 않는다.
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 8192)
        let ratio = 0.5

        let shifted = PitchShifterPSOLA.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate)

        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 440.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    func testIdentityRatioPreservesPitch() throws {
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 8192)
        let shifted = PitchShifterPSOLA.shift(samples: input, pitchRatio: 1.0, sampleRate: sampleRate)
        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(detected.frequency, 440.0, accuracy: 20)
    }

    func testOutputLengthMatchesInput() {
        // 리샘플링 단계가 없으므로 출력 길이는 pitchRatio와 무관하게 항상 입력과 정확히
        // 같다 — 그레인을 원래 위치에 겹쳐 더하기만 하기 때문이다.
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 8192)
        let shifted = PitchShifterPSOLA.shift(samples: input, pitchRatio: 1.26, sampleRate: sampleRate)
        XCTAssertEqual(shifted.count, input.count)
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(PitchShifterPSOLA.shift(samples: [], pitchRatio: 1.5, sampleRate: sampleRate).isEmpty)
    }

    // expectedFrequency를 넘겨도(로컬 피치 추정이 무음/실패한 구간의 대체값으로 쓰일 뿐) 결과
    // 피치 자체는 여전히 정확해야 한다.
    func testShiftWithExpectedFrequencyStillShiftsPitchCorrectly() throws {
        let input = voiceLikeWave(frequency: 220.0, sampleCount: 8192)
        let ratio = pow(2.0, 4.0 / 12.0) // 장3도 위

        let shifted = PitchShifterPSOLA.shift(samples: input, pitchRatio: ratio, sampleRate: sampleRate, expectedFrequency: 220.0)

        let middle = middleSegment(of: shifted, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = 220.0 * ratio
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    // MARK: - 1단계(estimateLocalPeriods) 단독 검증
    // (피치 추정 자체는 배음 유무와 무관하게 동작해야 하므로 여기는 순음으로 충분하다.)

    func testEstimateLocalPeriodsMatchesKnownFrequency() {
        // 440Hz 순음의 로컬 주기는 sampleRate/440 ≈ 100.2샘플이어야 한다.
        let input = sineWave(frequency: 440.0, sampleCount: 8192)
        let periods = PitchShifterPSOLA.estimateLocalPeriods(samples: input, sampleRate: sampleRate, fallbackFrequency: nil)

        XCTAssertEqual(periods.count, input.count)
        let middlePeriod = periods[periods.count / 2]
        XCTAssertEqual(middlePeriod, sampleRate / 440.0, accuracy: 2.0)
    }

    func testEstimateLocalPeriodsHoldsLastValueThroughSilence() {
        // 순음 -> 무음으로 이어지는 버퍼: 무음 구간도 직전 유효 주기를 그대로 이어써야 한다
        // (급격하게 fallback 값으로 끊기면 그 경계에서 그레인 배치가 들쭉날쭉해진다).
        let tone = sineWave(frequency: 300.0, sampleCount: 8192)
        let silence = [Float](repeating: 0, count: 4096)
        let input = tone + silence

        let periods = PitchShifterPSOLA.estimateLocalPeriods(samples: input, sampleRate: sampleRate, fallbackFrequency: 500.0)

        let lastPeriod = periods[periods.count - 1]
        let toneExpectedPeriod = sampleRate / 300.0
        // fallback(500Hz 주기)이 아니라 순음 구간의 마지막 유효 주기에 훨씬 더 가까워야 한다.
        XCTAssertEqual(lastPeriod, toneExpectedPeriod, accuracy: toneExpectedPeriod * 0.5)
    }

    func testEstimateLocalPeriodsUsesFallbackWhenTooShortToAnalyze() {
        let input = sineWave(frequency: 440.0, sampleCount: 100) // 분석 윈도우보다 훨씬 짧음
        let periods = PitchShifterPSOLA.estimateLocalPeriods(samples: input, sampleRate: sampleRate, fallbackFrequency: 300.0)

        XCTAssertEqual(periods.count, input.count)
        XCTAssertEqual(periods[0], sampleRate / 300.0, accuracy: 0.01)
    }

    // MARK: - 2단계(pitchSynchronousResynthesize) 단독 검증

    func testPitchSynchronousResynthesizeAtRatioOneApproximatesOriginal() throws {
        // pitchRatio 1.0(제자리)이면 그레인을 원래 위치에 원래 밀도로 다시 겹쳐 더하는
        // 것뿐이라, 결과 피치가 원본과 같아야 한다(진폭/미세 위상은 100% 동일하진 않을 수 있음).
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 8192)
        let periods = PitchShifterPSOLA.estimateLocalPeriods(samples: input, sampleRate: sampleRate, fallbackFrequency: nil)
        let output = PitchShifterPSOLA.pitchSynchronousResynthesize(samples: input, periods: periods, pitchRatio: 1.0)

        XCTAssertEqual(output.count, input.count)
        let middle = middleSegment(of: output, length: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: middle, sampleRate: sampleRate)
        let detected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(detected.frequency, 440.0, accuracy: 20)
    }

    func testPitchSynchronousResynthesizeOnEmptyInputReturnsEmpty() {
        XCTAssertTrue(PitchShifterPSOLA.pitchSynchronousResynthesize(samples: [], periods: [], pitchRatio: 1.2).isEmpty)
    }

    func testPitchSynchronousResynthesizeMostlyAvoidsSilentGapsWhenLoweringPitch() {
        // 그레인 반경을 "원본 주기 1개"로 좁게 잡았기 때문에(위 testShiftDownByOctaveLowers...
        // 주석 참고), 피치를 크게 내릴 때(step > 원래 주기)는 그레인 사이에 아주 짧게(수 샘플)
        // 커버되지 않는 지점이 드문드문 생길 수 있다. 여기서는 "거의 없다"(전체의 5% 미만)까지만
        // 확인한다 — 재생 시 클릭음으로 들릴 만큼 크진 않은 수준.
        let input = voiceLikeWave(frequency: 440.0, sampleCount: 8192)
        let periods = PitchShifterPSOLA.estimateLocalPeriods(samples: input, sampleRate: sampleRate, fallbackFrequency: nil)
        let output = PitchShifterPSOLA.pitchSynchronousResynthesize(samples: input, periods: periods, pitchRatio: 0.5)

        // 맨 앞/끝(그레인이 버퍼 경계에 걸려 부분적으로만 덮이는 구간) 제외하고 가운데를 본다.
        let middle = middleSegment(of: output, length: 4096)
        let nearSilentCount = middle.filter { abs($0) < 0.0001 }.count
        XCTAssertLessThan(Double(nearSilentCount) / Double(middle.count), 0.05)
    }
}
