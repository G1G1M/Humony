import XCTest
@testable import HarmonyUp

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
        XCTAssertNotNil(steps.first?.harmonyNames)
    }

    func testEmptyRecordingProducesNoStepsAndNoKey() {
        let analyzed = RecordingAnalyzer.analyze(recordingSamples: [], sampleRate: sampleRate)
        XCTAssertTrue(analyzed.notes.isEmpty)
        XCTAssertNil(analyzed.key)
        XCTAssertTrue(RecordingAnalyzer.melodySteps(from: analyzed).isEmpty)
    }
}
