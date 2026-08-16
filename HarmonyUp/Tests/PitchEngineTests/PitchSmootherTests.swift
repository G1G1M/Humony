import XCTest
@testable import HarmonyUp

final class PitchSmootherTests: XCTestCase {

    func testFirstValuePassesThroughUnchanged() {
        let smoother = PitchSmoother()
        let result = smoother.smooth(frequency: 440.0)
        XCTAssertEqual(result, 440.0, accuracy: 0.01)
    }

    func testSuddenJumpIsDampenedOnFirstFollowingFrame() {
        let smoother = PitchSmoother()
        _ = smoother.smooth(frequency: 440.0) // A4에서 시작

        // 다음 프레임에 반음 위(A#4)로 순간적으로 튀어도, 스무딩 때문에
        // 즉시 A#4로 점프하지 않고 그 사이 어딘가에 머물러야 한다.
        let jumpedFrequency = NoteNameConverter.frequency(forMIDINote: 70) // A#4
        let result = smoother.smooth(frequency: jumpedFrequency)

        XCTAssertGreaterThan(result, 440.0)
        XCTAssertLessThan(result, jumpedFrequency)
    }

    func testConvergesToSteadyFrequencyOverMultipleFrames() {
        let smoother = PitchSmoother()
        let target = 466.16 // A#4

        var last = 0.0
        for _ in 0..<30 {
            last = smoother.smooth(frequency: target)
        }

        XCTAssertEqual(last, target, accuracy: 0.5)
    }

    func testResetClearsPreviousHistory() {
        let smoother = PitchSmoother()
        _ = smoother.smooth(frequency: 440.0)
        smoother.reset()

        // 리셋 후 첫 값은 다시 그대로 통과해야 한다(이전 440Hz 영향이 남으면 안 됨).
        let result = smoother.smooth(frequency: 523.25) // C5
        XCTAssertEqual(result, 523.25, accuracy: 0.01)
    }
}
