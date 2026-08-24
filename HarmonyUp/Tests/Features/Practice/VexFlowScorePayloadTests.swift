import XCTest
@testable import HarmonyUp

/// 136절에 악보를 멜로디 1성부에서 4성부로 늘리면서 생긴 불변식들을 고정한다 — 특히
/// **모든 성부의 음 개수가 같고 마디 구성을 공유해야 마디선이 세로로 맞는다**는 조건은
/// 눈으로 악보를 봐서는 어긋나도 알아채기 어렵다(render.js 주석에 기록된 과거 정렬 버그가
/// 정확히 그 종류였다).
final class VexFlowScorePayloadTests: XCTestCase {

    // MARK: - 테스트 픽스처

    /// C장조에서 `ChordGenerator`가 실제로 내놓는 배치와 같은 형태의 화음을 손으로 만든다 —
    /// 베이스=근음(멜로디보다 9반음 이상 아래), 3도/5도는 그 베이스 바로 위 옥타브 밴드.
    private func harmony(bass: Int, third: Int, fifth: Int) -> [ChordGenerator.HarmonyNote] {
        [
            ChordGenerator.HarmonyNote(interval: .bass, midiNote: bass, frequency: NoteNameConverter.frequency(forMIDINote: bass), pitchClass: bass.mod(12)),
            ChordGenerator.HarmonyNote(interval: .third, midiNote: third, frequency: NoteNameConverter.frequency(forMIDINote: third), pitchClass: third.mod(12)),
            ChordGenerator.HarmonyNote(interval: .fifth, midiNote: fifth, frequency: NoteNameConverter.frequency(forMIDINote: fifth), pitchClass: fifth.mod(12)),
        ]
    }

    private func step(midiNote: Int, onset: Double, duration: Double = 0.3, harmony: [ChordGenerator.HarmonyNote]?) -> MelodyStep {
        MelodyStep(
            noteName: NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?",
            midiNote: midiNote,
            harmonyVoices: MelodyStep.harmonyVoices(from: harmony),
            harmony: harmony,
            onsetTime: onset,
            duration: duration
        )
    }

    /// C4 -> D4 -> E4 -> C4, 전부 같은 길이(4분음표), 각 음에 I 또는 ii 코드가 붙은 4스텝.
    private var fourStepMelody: [MelodyStep] {
        [
            step(midiNote: 60, onset: 0.0, harmony: harmony(bass: 48, third: 52, fifth: 55)), // C4 / C3-E3-G3
            step(midiNote: 62, onset: 0.3, harmony: harmony(bass: 50, third: 53, fifth: 57)), // D4 / D3-F3-A3
            step(midiNote: 64, onset: 0.6, harmony: harmony(bass: 48, third: 52, fifth: 55)), // E4 / C3-E3-G3
            step(midiNote: 60, onset: 0.9, harmony: harmony(bass: 48, third: 52, fifth: 55)), // C4 / C3-E3-G3
        ]
    }

    // MARK: - 빈 입력

    func testEmptyStepsProduceEmptyPayload() {
        XCTAssertEqual(VexFlowScorePayload.build(steps: []), VexFlowScorePayload.empty)
    }

    /// onsetTime이 없는 스텝은 리듬을 알 수 없어 악보에 그릴 수 없다 — 통째로 빈 악보가 돼야 한다.
    func testStepsWithoutOnsetTimeAreExcluded() {
        let step = MelodyStep(noteName: "C4", midiNote: 60, harmonyVoices: nil, harmony: nil, onsetTime: nil, duration: nil)
        XCTAssertEqual(VexFlowScorePayload.build(steps: [step]), VexFlowScorePayload.empty)
    }

    // MARK: - 4성부 구성

    func testBuildsFourVoicesInDescendingPitchOrder() {
        let payload = VexFlowScorePayload.build(steps: fourStepMelody)
        XCTAssertEqual(payload.voices.count, 4)

        // 첫 스텝(멜로디 C4=60, 5도 G3=55, 3도 E3=52, 베이스 C3=48)의 음이 위에서 아래로
        // 높은 순서대로 배치돼야 한다 — 오선보 관례. VexFlow 옥타브 표기는 MIDI 60 = c/4다.
        XCTAssertEqual(payload.voices.map { $0.notes[0].key }, ["c/4", "g/3", "e/3", "c/3"])
    }

    /// 성부마다 음 개수가 다르면 render.js에서 같은 자리의 마디가 서로 다른 순간을 가리키게 된다.
    func testAllVoicesHaveSameNoteCountAsMeasureBreaksTotal() {
        let payload = VexFlowScorePayload.build(steps: fourStepMelody)
        let total = payload.measureBreaks.reduce(0, +)
        XCTAssertEqual(total, 4)
        for voice in payload.voices {
            XCTAssertEqual(voice.notes.count, total, "성부(\(voice.clef))의 음 개수가 마디 구성 합과 다르다")
        }
    }

    /// 화음이 없는 스텝(온음계 밖 등)은 그 성부에서 쉼표(key: nil)가 되고, 멜로디는 그대로
    /// 음을 유지해야 한다 — 건너뛰면 성부별 음 개수가 어긋난다.
    func testStepWithoutHarmonyBecomesRestInHarmonyVoicesOnly() {
        var steps = fourStepMelody
        steps[1] = step(midiNote: 61, onset: 0.3, harmony: nil) // C#4, 화음 없음
        let payload = VexFlowScorePayload.build(steps: steps)

        XCTAssertEqual(payload.voices.count, 4)
        // 멜로디(첫 행)는 음이 있고, 나머지 세 성부는 그 자리가 쉼표다.
        XCTAssertEqual(payload.voices[0].notes[1].key, "c/4") // C#4는 c/4 + 샵
        XCTAssertTrue(payload.voices[0].notes[1].sharp)
        for voice in payload.voices.dropFirst() {
            XCTAssertNil(voice.notes[1].key, "화음 성부(\(voice.clef))의 빈 자리가 쉼표가 아니다")
        }
        // 쉼표를 넣어 개수를 맞췄으니 전 성부가 여전히 같은 길이다.
        XCTAssertTrue(payload.voices.allSatisfy { $0.notes.count == 4 })
    }

    /// 조성을 못 잡아 화음이 전혀 안 붙은 녹음은 멜로디 한 행만 그린다 — 쉼표만 가득한
    /// 빈 오선 3개를 그리지 않는다.
    func testMelodyOnlyWhenNoHarmonyAtAll() {
        let steps = (0..<4).map { step(midiNote: 60 + $0, onset: Double($0) * 0.3, harmony: nil) }
        let payload = VexFlowScorePayload.build(steps: steps)
        XCTAssertEqual(payload.voices.count, 1)
        XCTAssertTrue(payload.voices[0].notes.allSatisfy { $0.key != nil })
    }

    /// 베이스 성부는 실제 음역이 낮으니 낮은음자리표로 떨어져야 한다(멜로디는 높은음자리표).
    func testClefIsChosenPerVoiceByItsOwnRange() {
        // 멜로디를 한 옥타브 올려서(C5=72) 베이스가 확실히 낮은음자리표 영역(C4=60 미만)에 오게 한다.
        let steps = [
            step(midiNote: 72, onset: 0.0, harmony: harmony(bass: 60, third: 64, fifth: 67)),
            step(midiNote: 74, onset: 0.3, harmony: harmony(bass: 50, third: 53, fifth: 57)),
            step(midiNote: 72, onset: 0.6, harmony: harmony(bass: 48, third: 52, fifth: 55)),
        ]
        let payload = VexFlowScorePayload.build(steps: steps)
        XCTAssertEqual(payload.voices.first?.clef, "treble")
        XCTAssertEqual(payload.voices.last?.clef, "bass")
    }

    // MARK: - 마디 구성 공유

    /// 마디가 여러 개로 나뉘어도 전 성부가 같은 구성을 공유해야 한다.
    func testMeasureBreaksAreSharedAcrossVoices() {
        // 4분음표 6개 -> [4, 2]
        let steps = (0..<6).map { index in
            step(midiNote: 60 + (index % 3), onset: Double(index) * 0.3, harmony: harmony(bass: 48, third: 52, fifth: 55))
        }
        let payload = VexFlowScorePayload.build(steps: steps)
        XCTAssertEqual(payload.measureBreaks, [4, 2])
        XCTAssertTrue(payload.voices.allSatisfy { $0.notes.count == 6 })
    }

    // MARK: - MIDI -> VexFlow 표기

    func testVexFlowKeyUsesDiatonicLetterWithSharp() {
        XCTAssertEqual(VexFlowScorePayload.vexFlowKey(forMIDINote: 60).key, "c/4")
        XCTAssertFalse(VexFlowScorePayload.vexFlowKey(forMIDINote: 60).sharp)

        // C#4는 아래 자연음 C와 같은 레터를 쓰고 샵만 붙인다(플랫 표기는 안 쓴다).
        XCTAssertEqual(VexFlowScorePayload.vexFlowKey(forMIDINote: 61).key, "c/4")
        XCTAssertTrue(VexFlowScorePayload.vexFlowKey(forMIDINote: 61).sharp)

        // 옥타브 경계 — B3은 MIDI 59로 옥타브가 3이어야 한다(60부터 4옥타브).
        XCTAssertEqual(VexFlowScorePayload.vexFlowKey(forMIDINote: 59).key, "b/3")
    }

    // MARK: - JSON

    /// render.js가 `key === null`을 쉼표로 해석하므로, 쉼표는 JSON에서도 null로 나가야 한다
    /// (키가 아예 빠지면 JS에서 undefined가 되는데 그건 falsy라 지금은 우연히 동작하지만,
    /// 계약을 명시적으로 지켜둔다).
    func testJSONEncodesRestAsExplicitNull() {
        var steps = fourStepMelody
        steps[1] = step(midiNote: 61, onset: 0.3, harmony: nil)
        let json = VexFlowScorePayload.json(steps: steps)
        XCTAssertTrue(json.contains("\"key\":null"), "쉼표가 JSON에서 null로 인코딩되지 않았다")
        XCTAssertTrue(json.contains("\"measureBreaks\""))
    }

    /// 빈 악보도 render.js가 그대로 먹을 수 있는 형태여야 한다 — JSON 키 순서는 인코더가
    /// 정하는 것이라(실제로 measureBreaks가 먼저 나온다) 문자열 비교 대신 파싱해서 확인한다.
    func testJSONOnEmptyStepsIsValidEmptyScore() throws {
        let json = VexFlowScorePayload.json(steps: [])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual((object["voices"] as? [Any])?.count, 0)
        XCTAssertEqual((object["measureBreaks"] as? [Any])?.count, 0)
    }
}
