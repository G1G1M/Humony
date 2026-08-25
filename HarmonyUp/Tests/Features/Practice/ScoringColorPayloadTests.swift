import XCTest
@testable import HarmonyUp

/// 채점 결과를 악보 음표 색으로 옮기는 매핑(159절)을 고정한다.
///
/// **이 테스트가 지키는 것은 "인덱스 공간 세 개가 어긋나지 않는다"는 계약 하나다.**
/// - 채점 인덱스 = 목표 성부의 음 순서(`HarmonyPracticeScorer.targetFrequencies`가 뽑는 것)
/// - 악보 스텝 인덱스 = `ScoreTimeline` 이벤트 순서(**쉼표가 자리를 차지한다**)
/// - 악보 행 인덱스 = 실제로 그려진 성부의 순서(음이 하나도 없는 성부는 행 자체가 빠진다)
///
/// 149·158절에 같은 종류(정렬 안 한 두 배열을 그냥 이어붙임)로 두 번 데였다 — 그래서 뷰에서
/// 인덱스를 계산하지 않고 여기 순수 함수로 몰아넣고, 어긋날 수 있는 경우를 전부 테스트로 박는다.
final class ScoringColorPayloadTests: XCTestCase {

    // MARK: - 테스트 픽스처

    private func harmony(bass: Int, third: Int, fifth: Int) -> [ChordGenerator.HarmonyNote] {
        [
            ChordGenerator.HarmonyNote(interval: .bass, midiNote: bass, frequency: NoteNameConverter.frequency(forMIDINote: bass), pitchClass: bass.mod(12)),
            ChordGenerator.HarmonyNote(interval: .third, midiNote: third, frequency: NoteNameConverter.frequency(forMIDINote: third), pitchClass: third.mod(12)),
            ChordGenerator.HarmonyNote(interval: .fifth, midiNote: fifth, frequency: NoteNameConverter.frequency(forMIDINote: fifth), pitchClass: fifth.mod(12)),
        ]
    }

    private func step(midiNote: Int, onset: Double?, duration: Double = 0.3, harmony: [ChordGenerator.HarmonyNote]?) -> MelodyStep {
        MelodyStep(
            noteName: NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?",
            midiNote: midiNote,
            harmonyVoices: MelodyStep.harmonyVoices(from: harmony),
            harmony: harmony,
            onsetTime: onset,
            duration: duration
        )
    }

    /// 3도 성부가 52 -> 57 -> 62 -> 67로 **뚜렷하게 벌어지는** 4스텝. 간격을 넓게 잡은 건
    /// 편집거리 정렬(`MelodyAligner`)이 어느 음을 누락으로 볼지 예측 가능하게 만들기 위해서다.
    private var fourSteps: [MelodyStep] {
        [
            step(midiNote: 64, onset: 0.0, harmony: harmony(bass: 40, third: 52, fifth: 47)),
            step(midiNote: 69, onset: 0.3, harmony: harmony(bass: 45, third: 57, fifth: 52)),
            step(midiNote: 74, onset: 0.6, harmony: harmony(bass: 50, third: 62, fifth: 57)),
            step(midiNote: 79, onset: 0.9, harmony: harmony(bass: 55, third: 67, fifth: 62)),
        ]
    }

    private func frequency(_ midiNote: Int) -> Double { NoteNameConverter.frequency(forMIDINote: midiNote) }

    /// 실제 채점기를 그대로 돌려서 결과를 만든다 — `Result`를 손으로 조립하면 "steps가 목표
    /// 순서를 그대로 따른다"는 전제 자체를 테스트가 검증하지 못한다.
    private func score(_ steps: [MelodyStep], sung: [Double]) -> HarmonyPracticeScorer.Result {
        let targets = HarmonyPracticeScorer.targetFrequencies(from: steps, interval: .third)
        return HarmonyPracticeScorer.score(targetFrequencies: targets, sungFrequencies: sung)!
    }

    // MARK: - 성부 행

    /// 4성부가 다 그려지면 3도는 위에서 세 번째 행이다(멜로디 - 5도 - 3도 - 베이스).
    func testThirdVoiceMapsToThirdRow() {
        let result = score(fourSteps, sung: [52, 57, 62, 67].map(frequency))
        let entries = ScoringColorPayload.entries(steps: fourSteps, interval: .third, result: result)

        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(Set(entries.map(\.voice)), [2])
    }

    /// 화음이 아예 없는 녹음은 화음 행이 그려지지 않는다 — 칠할 자리도 없다.
    func testNoHarmonyProducesNoEntries() {
        let steps = [
            step(midiNote: 64, onset: 0.0, harmony: nil),
            step(midiNote: 69, onset: 0.3, harmony: nil),
        ]
        let result = HarmonyPracticeScorer.Result(
            steps: [.init(targetMIDINote: 52, sungMIDINote: 52, centsOffset: 0, isOnPitch: true)],
            onPitchRatio: 1, averageAbsCentsOffset: 0, averageSignedCentsOffset: 0, missedCount: 0, extraCount: 0
        )
        XCTAssertTrue(ScoringColorPayload.entries(steps: steps, interval: .third, result: result).isEmpty)
    }

    // MARK: - 상태별 색

    func testAllOnPitchNotesGetOnPitchColor() {
        let result = score(fourSteps, sung: [52, 57, 62, 67].map(frequency))
        let entries = ScoringColorPayload.entries(steps: fourSteps, interval: .third, result: result)

        XCTAssertEqual(entries.map(\.step), [0, 1, 2, 3])
        XCTAssertEqual(entries.map(\.color), Array(repeating: ScoringColorPayload.onPitchColor, count: 4))
    }

    /// 두 번째 음만 반음(100cent) 높게 불렀다 — 허용 오차(35cent) 밖이라 "벗어남"이다.
    func testOffPitchNoteGetsOffPitchColor() {
        let result = score(fourSteps, sung: [52, 58, 62, 67].map(frequency))
        let entries = ScoringColorPayload.entries(steps: fourSteps, interval: .third, result: result)

        XCTAssertEqual(entries.map(\.color), [
            ScoringColorPayload.onPitchColor,
            ScoringColorPayload.offPitchColor,
            ScoringColorPayload.onPitchColor,
            ScoringColorPayload.onPitchColor,
        ])
    }

    /// 두 번째 음을 아예 안 불렀다 — 짝을 못 찾은 목표음은 "안 부름" 색이 된다.
    /// (57을 건너뛰는 비용 600 < 나머지를 한 칸씩 밀어 짝짓는 비용 1000)
    func testMissedNoteGetsMissedColor() {
        let result = score(fourSteps, sung: [52, 62, 67].map(frequency))
        let entries = ScoringColorPayload.entries(steps: fourSteps, interval: .third, result: result)

        XCTAssertEqual(entries.map(\.color), [
            ScoringColorPayload.onPitchColor,
            ScoringColorPayload.missedColor,
            ScoringColorPayload.onPitchColor,
            ScoringColorPayload.onPitchColor,
        ])
    }

    // MARK: - 인덱스가 어긋나는 자리들

    /// **쉼표는 악보에서 한 자리를 차지한다.** 두 번째 음 뒤에 쉼표가 들어가면 그 뒤 음표의
    /// 스텝 인덱스가 하나씩 밀린다 — 채점 인덱스를 그대로 쓰면 엉뚱한 음표가 칠해진다.
    func testRestShiftsStepIndex() {
        let steps = [
            step(midiNote: 64, onset: 0.0, harmony: harmony(bass: 40, third: 52, fifth: 47)),
            step(midiNote: 69, onset: 0.3, harmony: harmony(bass: 45, third: 57, fifth: 52)),
            step(midiNote: 74, onset: 1.0, harmony: harmony(bass: 50, third: 62, fifth: 57)), // 앞에 0.4초 쉼표
            step(midiNote: 79, onset: 1.3, harmony: harmony(bass: 55, third: 67, fifth: 62)),
        ]
        let result = score(steps, sung: [52, 57, 62, 67].map(frequency))
        let entries = ScoringColorPayload.entries(steps: steps, interval: .third, result: result)

        XCTAssertEqual(entries.map(\.step), [0, 1, 3, 4])
    }

    /// 화음이 안 붙은 스텝은 **채점 대상에서 빠지지만 악보에는 쉼표로 남는다** — 채점 결과
    /// 세 개가 악보의 0·2·3번 자리에 각각 붙어야 한다.
    func testStepWithoutHarmonyIsSkipped() {
        var steps = fourSteps
        steps[1] = step(midiNote: 69, onset: 0.3, harmony: nil)
        let result = score(steps, sung: [52, 62, 67].map(frequency))
        let entries = ScoringColorPayload.entries(steps: steps, interval: .third, result: result)

        XCTAssertEqual(entries.map(\.step), [0, 2, 3])
        XCTAssertEqual(entries.map(\.color), Array(repeating: ScoringColorPayload.onPitchColor, count: 3))
    }

    /// **채점은 `onsetTime`을 안 보고 악보는 본다.** onsetTime이 없는 스텝은 채점 목표에는
    /// 들어가지만 악보에는 그려지지 않는다 — 그 자리를 조용히 건너뛰고, 뒤의 짝은 그대로여야 한다.
    func testStepWithoutOnsetTimeIsSkippedWithoutShiftingTheRest() {
        var steps = fourSteps
        steps[1] = step(midiNote: 69, onset: nil, harmony: harmony(bass: 45, third: 57, fifth: 52))
        // 앞 음을 그 자리까지 길게 늘려 쉼표가 생기지 않게 한다 — 쉼표로 인한 밀림은
        // `testRestShiftsStepIndex`가 따로 보고 있어서, 여기선 그 변수를 빼고 본다.
        steps[0] = step(midiNote: 64, onset: 0.0, duration: 0.6, harmony: harmony(bass: 40, third: 52, fifth: 47))
        let result = score(steps, sung: [52, 62, 67].map(frequency)) // 57은 안 불렀다
        let entries = ScoringColorPayload.entries(steps: steps, interval: .third, result: result)

        // 악보에 남은 음표는 세 개(0·1·2번 자리)이고, 각각 52·62·67의 채점 결과다.
        XCTAssertEqual(entries.map(\.step), [0, 1, 2])
        XCTAssertEqual(entries.map(\.color), Array(repeating: ScoringColorPayload.onPitchColor, count: 3))
    }

    /// 채점 결과 개수와 목표 개수가 안 맞으면(전제가 깨진 상황) **아무것도 칠하지 않는다** —
    /// 앞에서부터 zip으로 붙이면 조용히 어긋난 색이 화면에 남는데, 그게 제일 나쁘다.
    func testCountMismatchProducesNoEntries() {
        let result = HarmonyPracticeScorer.Result(
            steps: [.init(targetMIDINote: 52, sungMIDINote: 52, centsOffset: 0, isOnPitch: true)],
            onPitchRatio: 1, averageAbsCentsOffset: 0, averageSignedCentsOffset: 0, missedCount: 0, extraCount: 0
        )
        XCTAssertTrue(ScoringColorPayload.entries(steps: fourSteps, interval: .third, result: result).isEmpty)
    }

    // MARK: - JSON

    func testJSONIsAnArrayRenderJSCanRead() throws {
        let result = score(fourSteps, sung: [52, 57, 62, 67].map(frequency))
        let json = ScoringColorPayload.json(steps: fourSteps, interval: .third, result: result)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]

        XCTAssertEqual(decoded?.count, 4)
        XCTAssertEqual(decoded?.first?["voice"] as? Int, 2)
        XCTAssertEqual(decoded?.first?["step"] as? Int, 0)
        XCTAssertEqual(decoded?.first?["color"] as? String, ScoringColorPayload.onPitchColor)
    }

    func testEmptyEntriesProduceEmptyJSONArray() {
        let result = HarmonyPracticeScorer.Result(
            steps: [], onPitchRatio: 0, averageAbsCentsOffset: 0, averageSignedCentsOffset: 0, missedCount: 0, extraCount: 0
        )
        XCTAssertEqual(ScoringColorPayload.json(steps: [], interval: .third, result: result), "[]")
    }
}
