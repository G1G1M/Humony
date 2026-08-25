import XCTest
@testable import Humony

final class RecordingAnalyzerTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func sineWave(midiNote: Int, sampleCount: Int) -> [Float] {
        let frequency = NoteNameConverter.frequency(forMIDINote: midiNote)
        return (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    // C장조 삼화음을 아르페지오로("도-미-솔-도") 이어붙인 합성 버퍼 — 셋 다 C장조의
    // 가장 중심적인 음(으뜸음/장3도/완전5도)이라 조성 판별이 C장조로 뚜렷하게 나와야 한다.
    private func cMajorArpeggio() -> [Float] {
        sineWave(midiNote: 60, sampleCount: 8192)  // C4
            + sineWave(midiNote: 64, sampleCount: 8192)  // E4
            + sineWave(midiNote: 67, sampleCount: 8192)  // G4
            + sineWave(midiNote: 72, sampleCount: 8192)  // C5
    }

    func testAnalyzeDetectsKeyAndHarmonyForEachNote() throws {
        let analyzed = RecordingAnalyzer.analyze(recordingSamples: cMajorArpeggio(), sampleRate: sampleRate)

        XCTAssertEqual(analyzed.notes.map(\.midiNote), [60, 64, 67, 72])

        let key = try XCTUnwrap(analyzed.key)
        XCTAssertEqual(key.tonicPitchClass, 0) // C
        XCTAssertEqual(key.mode, .major)

        // 화음이 없는 인덱스가 없어야 한다 — 넷 다 온음계 안 음이므로.
        XCTAssertEqual(analyzed.harmonies.count, 4)
        // 첫 음(C4)의 3도는 E, 5도는 G여야 한다(ChordGeneratorTests가 이미 검증한 것과 같은 값).
        let firstHarmony = try XCTUnwrap(analyzed.harmonies[0])
        XCTAssertEqual(firstHarmony.first { $0.interval == .third }?.pitchClass, 4) // E
        XCTAssertEqual(firstHarmony.first { $0.interval == .fifth }?.pitchClass, 7) // G
    }

    // MARK: - 악보를 붙였을 때 (155절)

    /// **회귀 방지의 핵심**: 악보를 안 주면 예전과 완전히 같아야 한다. 악보 없이 부르는 흐름이
    /// 이 기능 때문에 달라지면 안 된다.
    func testAnalyzeWithoutAScoreLeavesTheOldPathUntouched() {
        let analyzed = RecordingAnalyzer.analyze(recordingSamples: cMajorArpeggio(), sampleRate: sampleRate)

        XCTAssertNil(analyzed.scoreComparison)
    }

    /// 반음 흔들려 잘못 적힌 음이 악보 값으로 돌아온다 — 조성·화음이 그 위에서 다시 계산된다.
    func testAnalyzeWithAScoreSnapsStrayPitches() throws {
        // 도-미b-솔-도로 부른 셈(E4 자리를 반음 낮게) — 악보는 도-미-솔-도다.
        let samples = sineWave(midiNote: 60, sampleCount: 8192)
            + sineWave(midiNote: 63, sampleCount: 8192)
            + sineWave(midiNote: 67, sampleCount: 8192)
            + sineWave(midiNote: 72, sampleCount: 8192)
        let score = ScoreImporter.ImportedScore(
            notes: [60, 64, 67, 72].map { PitchedNote(midiNote: $0, duration: 1.0) },
            keyFifths: 0,
            keyMode: .major
        )

        let analyzed = RecordingAnalyzer.analyze(recordingSamples: samples, sampleRate: sampleRate, reference: score)
        let comparison = try XCTUnwrap(analyzed.scoreComparison)

        XCTAssertTrue(comparison.isApplied)
        XCTAssertEqual(analyzed.notes.map(\.midiNote), [60, 64, 67, 72])
        XCTAssertEqual(comparison.snappedCount, 1)
        // 조성은 악보 조표에서 온다 — 오디오 추정을 건너뛴다.
        XCTAssertEqual(analyzed.key?.tonicPitchClass, 0)
        XCTAssertEqual(analyzed.key?.confidence, 1.0)
    }

    func testMelodyStepsBridgesToExistingUIModel() throws {
        let analyzed = RecordingAnalyzer.analyze(recordingSamples: cMajorArpeggio(), sampleRate: sampleRate)
        let steps = RecordingAnalyzer.melodySteps(from: analyzed)

        XCTAssertEqual(steps.count, analyzed.notes.count)
        for (index, step) in steps.enumerated() {
            XCTAssertEqual(step.midiNote, analyzed.notes[index].midiNote)
            // 배치(빠른 녹음) 경로에서 나온 스텝은 실시간 캡처 경로와 달리 onsetTime/duration이
            // 항상 채워져 있어야 한다 — 이게 카라오케 하이라이트 동기화의 기반이 된다.
            XCTAssertNotNil(step.onsetTime)
            XCTAssertNotNil(step.duration)
        }
        XCTAssertEqual(steps.first?.noteName, "C4")
        let firstVoices = try XCTUnwrap(steps.first?.harmonyVoices)
        XCTAssertEqual(firstVoices[.bass], "C3")  // 근음, 1옥타브 아래
        XCTAssertEqual(firstVoices[.third], "E3")
        XCTAssertEqual(firstVoices[.fifth], "G3")
    }

    func testEmptyRecordingProducesNoStepsAndNoKey() {
        let analyzed = RecordingAnalyzer.analyze(recordingSamples: [], sampleRate: sampleRate)
        XCTAssertTrue(analyzed.notes.isEmpty)
        XCTAssertNil(analyzed.key)
        XCTAssertTrue(RecordingAnalyzer.melodySteps(from: analyzed).isEmpty)
    }
}
