import XCTest
@testable import Humony

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
    // MARK: - 마지막 음 으뜸음 단서 (148절, 실기기 실측 픽스처)

    /// 2026-08-24 실기기 로그의 **실제 녹음 1** — `MelodySegmenter`가 뽑은 29개 음표 그대로.
    /// 원래도 G장조로 잘 나오던 녹음이다(상관 0.8601 vs 2위 C장조 0.5918).
    private var realRecordingInGMajor: [KeyDetector.WeightedNote] {
        [(2,0.64),(7,0.84),(6,0.34),(4,0.67),(7,0.44),(2,0.50),(11,0.63),(2,0.32),(7,0.60),(9,0.30),
         (11,0.31),(0,0.87),(11,0.38),(9,1.22),(2,0.87),(0,0.33),(11,0.62),(9,0.59),(7,0.62),(6,0.23),
         (6,0.10),(4,0.31),(2,0.63),(11,0.20),(2,0.64),(7,0.59),(9,0.66),(11,0.67),(7,1.32)]
            .map { KeyDetector.WeightedNote(pitchClass: $0.0, duration: $0.1) }
    }

    /// 2026-08-24 실기기 로그의 **실제 녹음 2** — 32개 음표. 이게 문제의 녹음이다:
    /// C#장조(0.7263)와 F#장조(0.7188)가 사실상 동점이라 신뢰도가 0.03으로 나왔다.
    /// 마지막 음은 F#(1.23초, 이 녹음에서 가장 긴 음)이다.
    private var realRecordingWithAmbiguousKey: [KeyDetector.WeightedNote] {
        [(1,0.67),(0,0.23),(1,0.39),(11,0.34),(10,0.42),(7,0.62),(8,0.49),(3,0.79),(4,0.36),(3,0.07),
         (3,0.30),(5,0.30),(3,0.43),(1,0.50),(0,0.64),(1,0.63),(6,0.80),(6,0.27),(8,0.42),(6,0.45),
         (5,0.60),(3,0.51),(0,0.18),(1,0.36),(11,0.57),(10,0.52),(8,0.38),(1,0.31),(3,0.67),(4,0.33),
         (5,0.91),(6,1.23)]
            .map { KeyDetector.WeightedNote(pitchClass: $0.0, duration: $0.1) }
    }

    /// 1·2위가 거의 붙어 있으면 마지막 음이 결정한다 — 노래는 으뜸음으로 끝나는 경우가 많다.
    func testNearTieIsBrokenByTheFinalNote() throws {
        let key = try XCTUnwrap(KeyDetector.detectKey(notes: realRecordingWithAmbiguousKey))
        XCTAssertEqual(key.tonicPitchClass, 6, "마지막 음 F#이 으뜸음인 조성으로 정해져야 한다, 실제 \(key.name)")
        XCTAssertEqual(key.mode, .major)
    }

    /// 이미 잘 나오던 녹음은 건드리면 안 된다(같은 로그의 다른 녹음).
    func testClearlyDetectedKeyIsUnchangedByTheFinalNoteHint() throws {
        let key = try XCTUnwrap(KeyDetector.detectKey(notes: realRecordingInGMajor))
        XCTAssertEqual(key.tonicPitchClass, 7, "G장조여야 한다, 실제 \(key.name)")
        XCTAssertEqual(key.mode, .major)
        XCTAssertGreaterThan(key.confidence, 0.7, "확실한 판별인데 신뢰도가 낮다")
    }

    /// **가산점 크기의 안전장치** — 프레이즈 중간에서 멈춰 으뜸음이 아닌 음으로 끝나도,
    /// 1위가 명확하면 뒤집히면 안 된다. 이게 깨지면 가산점이 너무 큰 것이다.
    func testFinalNoteHintCannotOverrideAClearWinner() throws {
        // C장조 음계를 골고루 부르되 마지막을 E(으뜸음 아님)로 끝낸다.
        let notes: [KeyDetector.WeightedNote] = [(0,1.0),(2,0.5),(4,0.5),(5,0.5),(7,1.0),(9,0.5),(11,0.5),(0,1.0),(7,1.0),(4,1.2)]
            .map { KeyDetector.WeightedNote(pitchClass: $0.0, duration: $0.1) }

        let key = try XCTUnwrap(KeyDetector.detectKey(notes: notes))
        XCTAssertEqual(key.tonicPitchClass, 0, "명확한 C장조가 마지막 음 E 때문에 뒤집혔다, 실제 \(key.name)")
        XCTAssertEqual(key.mode, .major)
    }

}
