import XCTest
@testable import Humony

/// 136절 채점 재설계 — "성부 하나를 먼저 들어보고, 소리를 끄고, 그 성부 한 소절을 통째로
/// 불러서 배치로 채점한다"는 흐름의 채점 엔진. 부른 음의 개수/템포가 목표와 다를 수 있으므로
/// 정렬(alignment)이 핵심이다.
final class HarmonyPracticeScorerTests: XCTestCase {

    /// 테스트 가독성을 위해 MIDI 노트로 목표/부른 음을 적고 주파수로 바꿔 넣는다.
    private func frequencies(_ midiNotes: [Int]) -> [Double] {
        midiNotes.map { NoteNameConverter.frequency(forMIDINote: $0) }
    }

    /// 특정 음을 cent 단위로 미세하게 벗어나게 부른 상황을 만든다.
    private func frequency(_ midiNote: Int, offsetCents: Double) -> Double {
        NoteNameConverter.frequency(forMIDINote: Double(midiNote) + offsetCents / 100.0)
    }

    // C장조 I 코드의 3도 성부를 부르는 상황: E3 - F3 - E3 - E3
    private let target = [52, 53, 52, 52]

    // MARK: - 기본

    func testPerfectMatchScoresFullAccuracy() throws {
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(
            targetFrequencies: frequencies(target),
            sungFrequencies: frequencies(target)
        ))

        XCTAssertEqual(result.steps.count, 4)
        XCTAssertEqual(result.onPitchRatio, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.missedCount, 0)
        XCTAssertEqual(result.extraCount, 0)
        XCTAssertEqual(result.averageAbsCentsOffset, 0, accuracy: 0.5)
        XCTAssertTrue(result.steps.allSatisfy { $0.isOnPitch })
    }

    func testEmptyTargetReturnsNil() {
        XCTAssertNil(HarmonyPracticeScorer.score(targetFrequencies: [], sungFrequencies: frequencies(target)))
    }

    /// 아무 소리도 안 낸 채 중지하면 모든 목표음이 누락으로 남는다 — 정확도 0이지만
    /// nil(채점 불가)은 아니어야 한다. 저장할 가치가 있는 "다 놓쳤다"는 결과다.
    func testNothingSungMeansEverythingMissed() throws {
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(
            targetFrequencies: frequencies(target),
            sungFrequencies: []
        ))
        XCTAssertEqual(result.missedCount, 4)
        XCTAssertEqual(result.onPitchRatio, 0)
        XCTAssertTrue(result.steps.allSatisfy { $0.sungMIDINote == nil })
    }

    // MARK: - 허용 오차

    /// 허용 오차(PitchScorer.onPitchToleranceCents = 35cent) 안이면 정확하게 부른 것으로 센다.
    func testWithinToleranceCountsAsOnPitch() throws {
        let sung = target.map { frequency($0, offsetCents: 20) }
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(targetFrequencies: frequencies(target), sungFrequencies: sung))
        XCTAssertEqual(result.onPitchRatio, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.averageAbsCentsOffset, 20, accuracy: 1.0)
    }

    func testOutsideToleranceIsNotOnPitch() throws {
        let sung = target.map { frequency($0, offsetCents: 45) }
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(targetFrequencies: frequencies(target), sungFrequencies: sung))
        XCTAssertEqual(result.onPitchRatio, 0)
        XCTAssertTrue(result.steps.allSatisfy { $0.sungMIDINote != nil }) // 짝은 지어졌다(누락이 아니다)
    }

    /// 높게/낮게 편향은 부호를 살려서 따로 봐야 알 수 있다 — 절대값 평균만으로는
    /// "전반적으로 높게 부르는 편"을 알려줄 수 없다.
    func testSignedOffsetRevealsSharpBias() throws {
        let sung = target.map { frequency($0, offsetCents: 30) }
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(targetFrequencies: frequencies(target), sungFrequencies: sung))
        XCTAssertEqual(result.averageSignedCentsOffset, 30, accuracy: 1.0)
        XCTAssertEqual(result.averageAbsCentsOffset, 30, accuracy: 1.0)
    }

    /// 반대로 높게/낮게가 섞이면 편향은 상쇄되지만 절대값 평균은 남는다.
    func testMixedDirectionOffsetsCancelInSignedAverage() throws {
        let sung = [
            frequency(target[0], offsetCents: 40),
            frequency(target[1], offsetCents: -40),
            frequency(target[2], offsetCents: 40),
            frequency(target[3], offsetCents: -40),
        ]
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(targetFrequencies: frequencies(target), sungFrequencies: sung))
        XCTAssertEqual(result.averageSignedCentsOffset, 0, accuracy: 1.0)
        XCTAssertEqual(result.averageAbsCentsOffset, 40, accuracy: 1.0)
    }

    // MARK: - 정렬 (핵심)

    /// 음 하나를 빠뜨려도 그 뒤가 전부 밀려서 오답이 되면 안 된다 — 순서대로 1:1 비교하던
    /// 방식의 치명적 약점이고, 정렬을 쓰는 이유 자체다.
    func testMissedNoteDoesNotShiftTheRest() throws {
        // 두 번째 음(F3=53)을 빠뜨렸다.
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(
            targetFrequencies: frequencies(target),
            sungFrequencies: frequencies([52, 52, 52])
        ))

        XCTAssertEqual(result.missedCount, 1)
        XCTAssertEqual(result.extraCount, 0)
        XCTAssertNil(result.steps[1].sungMIDINote)             // 빠뜨린 자리만 누락
        XCTAssertEqual(result.steps[0].sungMIDINote, 52)
        XCTAssertEqual(result.steps[2].sungMIDINote, 52)
        XCTAssertEqual(result.steps[3].sungMIDINote, 52)
        // 나머지 3개는 정확히 불렀으니 3/4
        XCTAssertEqual(result.onPitchRatio, 0.75, accuracy: 0.0001)
    }

    /// 목표에 없는 음을 하나 더 불러도 나머지 짝은 유지돼야 한다.
    func testExtraSungNoteIsCountedSeparately() throws {
        // 맨 앞에 군더더기 음(C3=48)을 하나 더 불렀다.
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(
            targetFrequencies: frequencies(target),
            sungFrequencies: frequencies([48, 52, 53, 52, 52])
        ))

        XCTAssertEqual(result.extraCount, 1)
        XCTAssertEqual(result.missedCount, 0)
        XCTAssertEqual(result.onPitchRatio, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.steps.map(\.sungMIDINote), [52, 53, 52, 52])
    }

    /// 템포가 달라도(전체를 두 배 느리게/빠르게 불러도) 음높이 시퀀스가 같으면 만점이어야
    /// 한다 — 채점은 음정을 보는 것이고, 이 앱은 애초에 템포를 강제하지 않는다. 이 엔진이
    /// 시간 정보를 아예 입력으로 받지 않는다는 설계 자체가 그 보장이다.
    func testTempoIndependence() throws {
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(
            targetFrequencies: frequencies(target),
            sungFrequencies: frequencies(target) // 같은 시퀀스, 길이 정보 없음
        ))
        XCTAssertEqual(result.onPitchRatio, 1.0, accuracy: 0.0001)
    }

    /// 전체를 반음 높게 부르면(조를 잘못 잡음) 짝은 1:1로 지어지고 전부 100cent 벗어난
    /// 것으로 나와야 한다 — "누락 4개 + 추가 4개"로 갈라지면 무슨 일이 있었는지 안 보인다.
    func testUniformlySharpSequenceStaysPairedNotSplit() throws {
        let sung = target.map { $0 + 1 }
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(
            targetFrequencies: frequencies(target),
            sungFrequencies: frequencies(sung)
        ))

        XCTAssertEqual(result.missedCount, 0)
        XCTAssertEqual(result.extraCount, 0)
        XCTAssertEqual(result.onPitchRatio, 0)
        XCTAssertEqual(result.averageSignedCentsOffset, 100, accuracy: 1.0)
    }

    /// 반대로 한 옥타브 넘게 동떨어진 음만 부른 경우는 짝을 짓지 않고 누락+추가로 갈라져야
    /// 한다 — "1900cent 벗어났다"는 숫자는 진단에 아무 도움이 안 된다.
    func testFarAwayNotesSplitIntoMissedAndExtra() throws {
        let result = try XCTUnwrap(HarmonyPracticeScorer.score(
            targetFrequencies: frequencies(target),
            sungFrequencies: frequencies(target.map { $0 + 19 }) // 한 옥타브+7반음 위
        ))

        XCTAssertEqual(result.missedCount, 4)
        XCTAssertEqual(result.extraCount, 4)
        XCTAssertEqual(result.onPitchRatio, 0)
    }
}

/// `HarmonyPracticeScorer`의 "녹음에서 채점까지" 진입점 — 뷰가 조립하던 로직을 밖으로 뺐으니
/// 여기도 테스트로 고정한다.
final class HarmonyPracticeScorerEntryPointTests: XCTestCase {

    private func harmonyNote(_ interval: ChordGenerator.Interval, _ midiNote: Int) -> ChordGenerator.HarmonyNote {
        ChordGenerator.HarmonyNote(
            interval: interval,
            midiNote: midiNote,
            frequency: NoteNameConverter.frequency(forMIDINote: midiNote),
            pitchClass: midiNote.mod(12)
        )
    }

    private func step(midiNote: Int, harmony: [ChordGenerator.HarmonyNote]?) -> MelodyStep {
        MelodyStep(
            noteName: "?",
            midiNote: midiNote,
            harmonyVoices: MelodyStep.harmonyVoices(from: harmony),
            harmony: harmony,
            onsetTime: 0,
            duration: 0.3
        )
    }

    func testTargetFrequenciesPicksOnlyTheChosenVoice() {
        let steps = [
            step(midiNote: 60, harmony: [harmonyNote(.bass, 48), harmonyNote(.third, 52), harmonyNote(.fifth, 55)]),
            step(midiNote: 62, harmony: [harmonyNote(.bass, 50), harmonyNote(.third, 53), harmonyNote(.fifth, 57)]),
        ]
        let thirds = HarmonyPracticeScorer.targetFrequencies(from: steps, interval: .third)
        XCTAssertEqual(thirds.count, 2)
        XCTAssertEqual(thirds[0], NoteNameConverter.frequency(forMIDINote: 52), accuracy: 0.01)
        XCTAssertEqual(thirds[1], NoteNameConverter.frequency(forMIDINote: 53), accuracy: 0.01)
    }

    /// 화음이 없는 스텝은 목표에서 빠져야 한다 — 부를 음이 없는 자리를 누락으로 세면
    /// 사용자가 잘 불렀는데도 감점된다.
    func testStepsWithoutHarmonyAreExcludedFromTargets() {
        let steps = [
            step(midiNote: 60, harmony: [harmonyNote(.third, 52)]),
            step(midiNote: 61, harmony: nil),
            step(midiNote: 62, harmony: [harmonyNote(.third, 53)]),
        ]
        XCTAssertEqual(HarmonyPracticeScorer.targetFrequencies(from: steps, interval: .third).count, 2)
    }

    func testTargetFrequenciesIsEmptyWhenVoiceMissing() {
        let steps = [step(midiNote: 60, harmony: [harmonyNote(.third, 52)])]
        XCTAssertTrue(HarmonyPracticeScorer.targetFrequencies(from: steps, interval: .bass).isEmpty)
    }

    /// 무음을 부른(=아무 소리도 안 낸) 녹음은 음이 하나도 안 잡히므로 전부 누락이 된다 —
    /// 세그멘테이션까지 실제로 태워서 진입점 배선이 이어져 있는지 확인한다.
    func testScoringSilentRecordingMarksEverythingMissed() throws {
        let sampleRate = 44100.0
        let silence = [Float](repeating: 0, count: Int(sampleRate)) // 1초 무음
        let targets = [52, 53].map { NoteNameConverter.frequency(forMIDINote: $0) }

        let result = try XCTUnwrap(HarmonyPracticeScorer.score(
            recordingSamples: silence,
            sampleRate: sampleRate,
            targetFrequencies: targets
        ))
        XCTAssertEqual(result.missedCount, 2)
        XCTAssertEqual(result.onPitchRatio, 0)
    }

    /// 목표음을 실제로 부른 것처럼 사인파를 만들어 넣으면 정확하게 채점돼야 한다 —
    /// 세그멘테이션(YIN+VAD+디바운스)을 통과하는 실측성 픽스처.
    func testScoringSustainedToneMatchesTarget() throws {
        let sampleRate = 44100.0
        let targetMIDI = 52 // E3
        let frequency = NoteNameConverter.frequency(forMIDINote: targetMIDI)
        // 1.5초 지속음 — MelodySegmenter의 최소 음 길이(0.18초)를 넉넉히 넘긴다.
        let sampleCount = Int(sampleRate * 1.5)
        let samples = (0..<sampleCount).map { index -> Float in
            let t = Double(index) / sampleRate
            // 순수 사인파는 VAD 에너지 임계값을 넘도록 진폭을 충분히 준다.
            return Float(0.3 * sin(2 * Double.pi * frequency * t))
        }

        let result = try XCTUnwrap(HarmonyPracticeScorer.score(
            recordingSamples: samples,
            sampleRate: sampleRate,
            targetFrequencies: [frequency]
        ))
        XCTAssertEqual(result.steps.count, 1)
        XCTAssertEqual(result.steps[0].sungMIDINote, targetMIDI)
        XCTAssertEqual(result.onPitchRatio, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.missedCount, 0)
    }
}
