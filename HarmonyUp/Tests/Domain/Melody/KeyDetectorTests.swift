import XCTest
@testable import HarmonyUp

final class KeyDetectorTests: XCTestCase {

    // Temperley 프로파일 자체를 그대로 입력으로 주면(모양이 100% 일치) 상관계수가 1.0이 되어
    // 해당 으뜸음/모드가 명확하게 1위로 뽑혀야 한다.
    private let majorProfile: [Double] = [5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0]
    private let minorProfile: [Double] = [5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 1.5, 4.0]

    private func rotate(_ profile: [Double], toTonic tonic: Int) -> [Double] {
        (0..<12).map { pitchClass in profile[((pitchClass - tonic) % 12 + 12) % 12] }
    }

    private func notes(from profile: [Double]) -> [KeyDetector.WeightedNote] {
        profile.enumerated().map { KeyDetector.WeightedNote(pitchClass: $0.offset, duration: $0.element) }
    }

    func testDetectsCMajorFromExactProfile() throws {
        let input = notes(from: rotate(majorProfile, toTonic: 0))
        let result = try XCTUnwrap(KeyDetector.detectKey(notes: input))

        XCTAssertEqual(result.tonicPitchClass, 0)
        XCTAssertEqual(result.mode, .major)
        XCTAssertGreaterThan(result.confidence, 0.5)
    }

    func testDetectsGMajorFromExactProfile() throws {
        let input = notes(from: rotate(majorProfile, toTonic: 7))
        let result = try XCTUnwrap(KeyDetector.detectKey(notes: input))

        XCTAssertEqual(result.tonicPitchClass, 7)
        XCTAssertEqual(result.mode, .major)
    }

    func testDetectsAMinorFromExactProfile() throws {
        let input = notes(from: rotate(minorProfile, toTonic: 9))
        let result = try XCTUnwrap(KeyDetector.detectKey(notes: input))

        XCTAssertEqual(result.tonicPitchClass, 9)
        XCTAssertEqual(result.mode, .minor)
    }

    func testUniformDistributionIsAmbiguous() throws {
        // 모든 pitch class를 똑같은 길이로 냈다면(예: 반음계를 고르게 부름) 특정 조성으로 쏠릴 근거가 없다.
        let input = (0..<12).map { KeyDetector.WeightedNote(pitchClass: $0, duration: 1.0) }
        let result = try XCTUnwrap(KeyDetector.detectKey(notes: input))

        XCTAssertEqual(result.confidence, 0, accuracy: 0.01)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(KeyDetector.detectKey(notes: []))
    }

    func testNameFormatting() throws {
        let input = notes(from: rotate(majorProfile, toTonic: 0))
        let result = try XCTUnwrap(KeyDetector.detectKey(notes: input))
        XCTAssertEqual(result.name, "C Major")
    }
}
