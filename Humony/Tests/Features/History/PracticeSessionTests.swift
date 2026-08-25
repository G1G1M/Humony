import XCTest
import SwiftData
@testable import Humony

/// 기록에서 "그때 부른 악보를 다시 보기"가 성립하려면 `snapshot(of:)`로 저장한 것이
/// `melodySteps()`로 그대로 되살아나야 한다 — 그 왕복을 고정한다(136절). 오디오를 저장하지
/// 않는 대신 음높이/길이만 남기는 설계라, 이 왕복이 깨지면 기록의 악보가 그때 부른 것과
/// 달라진다.
final class PracticeSessionTests: XCTestCase {

    private func harmony(bass: Int, third: Int, fifth: Int) -> [ChordGenerator.HarmonyNote] {
        [
            ChordGenerator.HarmonyNote(interval: .bass, midiNote: bass, frequency: NoteNameConverter.frequency(forMIDINote: bass), pitchClass: bass.mod(12)),
            ChordGenerator.HarmonyNote(interval: .third, midiNote: third, frequency: NoteNameConverter.frequency(forMIDINote: third), pitchClass: third.mod(12)),
            ChordGenerator.HarmonyNote(interval: .fifth, midiNote: fifth, frequency: NoteNameConverter.frequency(forMIDINote: fifth), pitchClass: fifth.mod(12)),
        ]
    }

    private func step(midiNote: Int, duration: Double, harmony: [ChordGenerator.HarmonyNote]?) -> MelodyStep {
        MelodyStep(
            noteName: NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?",
            midiNote: midiNote,
            harmonyVoices: MelodyStep.harmonyVoices(from: harmony),
            harmony: harmony,
            onsetTime: 0,
            duration: duration
        )
    }

    private var originalSteps: [MelodyStep] {
        [
            step(midiNote: 60, duration: 0.30, harmony: harmony(bass: 48, third: 52, fifth: 55)),
            step(midiNote: 62, duration: 0.45, harmony: harmony(bass: 50, third: 53, fifth: 57)),
            step(midiNote: 64, duration: 0.30, harmony: harmony(bass: 48, third: 52, fifth: 55)),
        ]
    }

    func testSnapshotRoundTripPreservesMelody() {
        let session = PracticeSession.snapshot(of: originalSteps, keyName: "C장조", date: Date())
        let restored = session.melodySteps()

        XCTAssertEqual(restored.count, 3)
        XCTAssertEqual(restored.map(\.midiNote), [60, 62, 64])
        XCTAssertEqual(restored.map { $0.duration ?? 0 }, [0.30, 0.45, 0.30])
        XCTAssertEqual(session.keyName, "C장조")
        XCTAssertEqual(session.noteCount, 3)
    }

    func testSnapshotRoundTripPreservesAllHarmonyVoices() {
        let session = PracticeSession.snapshot(of: originalSteps, keyName: "C장조", date: Date())
        let restored = session.melodySteps()

        for (index, step) in restored.enumerated() {
            let original = originalSteps[index]
            for interval in ChordGenerator.Interval.allCases {
                XCTAssertEqual(
                    step.harmony?.first { $0.interval == interval }?.midiNote,
                    original.harmony?.first { $0.interval == interval }?.midiNote,
                    "\(index)번째 스텝의 \(interval.koreanLabel)가 왕복에서 달라졌다"
                )
            }
        }
    }

    /// `onsetTime`은 저장하지 않고 길이를 누적해 되살린다 — 악보에 필요한 건 순서와 길이뿐이다.
    /// 누적이 어긋나면 `VexFlowScorePayload`가 스텝을 걸러버리므로(onsetTime nil 제외) 확인해둔다.
    func testRestoredStepsHaveAscendingOnsetTimes() {
        let restored = PracticeSession.snapshot(of: originalSteps, keyName: "C장조", date: Date()).melodySteps()
        let onsets = restored.compactMap(\.onsetTime)
        XCTAssertEqual(onsets.count, 3)
        XCTAssertEqual(onsets, [0.0, 0.30, 0.75])
    }

    /// 화음이 없는 스텝은 restMarker로 저장되고, 되살릴 때 그 스텝만 화음 없음으로 돌아와야
    /// 한다 — 배열 길이가 멜로디와 같아야 스텝이 어긋나지 않는다.
    func testStepWithoutHarmonyRoundTripsAsNil() {
        var steps = originalSteps
        steps[1] = step(midiNote: 61, duration: 0.3, harmony: nil)

        let restored = PracticeSession.snapshot(of: steps, keyName: "C장조", date: Date()).melodySteps()
        XCTAssertEqual(restored.count, 3)
        XCTAssertNotNil(restored[0].harmony)
        XCTAssertNil(restored[1].harmony, "화음 없는 스텝이 왕복에서 화음을 얻었다")
        XCTAssertNotNil(restored[2].harmony)
        XCTAssertEqual(restored[1].midiNote, 61) // 멜로디는 그대로
    }

    /// 조성을 못 잡아 화음이 전혀 없는 녹음은 성부 키를 아예 만들지 않는다.
    func testSessionWithNoHarmonyAtAllStoresNoVoices() {
        let steps = [step(midiNote: 60, duration: 0.3, harmony: nil), step(midiNote: 62, duration: 0.3, harmony: nil)]
        let session = PracticeSession.snapshot(of: steps, keyName: "판별 실패", date: Date())
        XCTAssertTrue(session.harmonyMIDINotes.isEmpty)
        XCTAssertTrue(session.melodySteps().allSatisfy { $0.harmony == nil })
    }

    /// 되살린 스텝으로 악보 페이로드가 정상적으로 만들어져야 한다 — 기록 화면이 기존
    /// `VexFlowScoreView`를 그대로 재사용하는 게 이 설계의 요점이다.
    func testRestoredStepsProduceFourVoiceScorePayload() {
        let restored = PracticeSession.snapshot(of: originalSteps, keyName: "C장조", date: Date()).melodySteps()
        let payload = VexFlowScorePayload.build(steps: restored)

        XCTAssertEqual(payload.voices.count, 4)
        XCTAssertEqual(payload.measureBreaks.reduce(0, +), 3)
        XCTAssertTrue(payload.voices.allSatisfy { $0.notes.count == 3 })
    }

    // MARK: - 채점 결과 -> 저장 형태

    func testAttemptStoresOffTargetAndMissedNotes() {
        let result = HarmonyPracticeScorer.score(
            targetFrequencies: [52, 53, 52].map { NoteNameConverter.frequency(forMIDINote: $0) },
            // 첫 음은 정확히, 두 번째는 크게 벗어나게(반음), 세 번째는 아예 안 부름
            sungFrequencies: [
                NoteNameConverter.frequency(forMIDINote: 52),
                NoteNameConverter.frequency(forMIDINote: 54),
            ]
        )
        let attempt = PracticeAttempt(result: XCTUnwrap2(result), interval: .third, date: Date())

        XCTAssertEqual(attempt.intervalRawValue, "third")
        XCTAssertEqual(attempt.targetNoteCount, 3)
        // 정확히 부른 음(52)은 벗어난 목록에 안 들어간다.
        XCTAssertFalse(attempt.offTargetMIDINotes.contains(52) && attempt.offTargetCents.isEmpty)
        XCTAssertEqual(attempt.offTargetMIDINotes.count, attempt.offTargetCents.count)
        XCTAssertEqual(attempt.missedCount, attempt.missedMIDINotes.count)
    }

    /// XCTUnwrap은 throws라 위 테스트에서 쓰기 번거로워서 작은 헬퍼로 감쌌다.
    private func XCTUnwrap2<T>(_ value: T?) -> T {
        guard let value else {
            XCTFail("값이 nil이다")
            fatalError("테스트 실패")
        }
        return value
    }
}
