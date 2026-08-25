import XCTest
@testable import Humony

final class VoiceHarmonyTrackBuilderTests: XCTestCase {

    private let rate: Double = 44100.0

    private func sineWave(frequency: Double, sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / rate))
        }
    }

    private func step(midiNote: Int, onset: Double, duration: Double, harmony: [ChordGenerator.HarmonyNote]?) -> MelodyStep {
        MelodyStep(
            noteName: NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?",
            midiNote: midiNote,
            harmonyVoices: nil,
            harmony: harmony,
            onsetTime: onset,
            duration: duration
        )
    }

    private func harmonyNotes(bass: Int, third: Int, fifth: Int) -> [ChordGenerator.HarmonyNote] {
        [
            ChordGenerator.HarmonyNote(interval: .bass, midiNote: bass, frequency: NoteNameConverter.frequency(forMIDINote: bass), pitchClass: bass.mod(12)),
            ChordGenerator.HarmonyNote(interval: .third, midiNote: third, frequency: NoteNameConverter.frequency(forMIDINote: third), pitchClass: third.mod(12)),
            ChordGenerator.HarmonyNote(interval: .fifth, midiNote: fifth, frequency: NoteNameConverter.frequency(forMIDINote: fifth), pitchClass: fifth.mod(12)),
        ]
    }

    // 길이 보존 불변식 — SynthesizedHarmonyTrackBuilderTests와 같은 이유(107절 교훈)로 검증.
    func testBuildAlwaysMatchesBufferLength() {
        let steps = [
            step(midiNote: 60, onset: 0.1, duration: 0.3, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67)),
            step(midiNote: 62, onset: 0.5, duration: 0.2, harmony: harmonyNotes(bass: 50, third: 65, fifth: 69)),
        ]
        let bufferLength = Int(1.0 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)

        for voice: VoiceHarmonyTrackBuilder.Voice in [.melody, .harmony(.bass), .harmony(.third), .harmony(.fifth)] {
            let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: voice, rate: rate)
            XCTAssertEqual(track.count, bufferLength)
        }
    }

    // 멜로디 성부는 피치 시프트 없이(비율 1) 원본 목소리를 그대로 써야 한다.
    func testMelodyVoiceUsesSourceAudioUnshifted() throws {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: nil)]
        let bufferLength = Int(0.2 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength) // C4

        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .melody, rate: rate, fadeDuration: 0)
        let candidates = YINPitchDetector.detectPitch(samples: Array(track[1000..<5000]), sampleRate: rate)
        let detected = try XCTUnwrap(candidates.first)
        XCTAssertEqual(detected.frequency, 261.63, accuracy: 5)
    }

    // 화음 성부는 실제로 목표 주파수로 옮겨진 소리여야 한다(YIN으로 되짚어 검증 — PitchShifterTests와 같은 방식).
    func testHarmonyVoiceShiftsSourceToTargetFrequency() throws {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.3, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67))]
        let bufferLength = Int(0.3 * rate)
        let source = sineWave(frequency: NoteNameConverter.frequency(forMIDINote: 60), sampleCount: bufferLength) // C4를 불렀다고 가정

        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .harmony(.fifth), rate: rate, fadeDuration: 0)
        let candidates = YINPitchDetector.detectPitch(samples: Array(track[4000..<8000]), sampleRate: rate)
        let detected = try XCTUnwrap(candidates.first)

        let expectedFrequency = NoteNameConverter.frequency(forMIDINote: 67) // G4(5도)
        let cents = 1200.0 * log2(detected.frequency / expectedFrequency)
        XCTAssertEqual(cents, 0, accuracy: 50)
    }

    // 온음계 밖 음이라 화음이 nil인 스텝은 그 성부에서 무음이어야 한다.
    func testStepWithoutHarmonyProducesSilenceForThatVoice() {
        let steps = [step(midiNote: 61, onset: 0.0, duration: 0.1, harmony: nil)]
        let bufferLength = Int(0.1 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)

        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .harmony(.third), rate: rate)
        XCTAssertTrue(track.allSatisfy { $0 == 0 })
    }

    func testEmptyMelodyStepsProducesSilentBufferOfRequestedLength() {
        let track = VoiceHarmonyTrackBuilder.build(melodySteps: [], sourceBuffer: [], bufferLength: 500, voice: .melody, rate: rate)
        XCTAssertEqual(track, [Float](repeating: 0, count: 500))
    }

    // 무음 없이 이어지는 두 음도 크로스페이드 구간에서 무음까지 떨어지면 안 된다(121절과 같은 원칙).
    // 128절: 멜로디는 더 이상 크로스페이드 경로를 안 타므로(패스스루), 화음 성부로 검증한다.
    func testContiguousTransitionCrossfadesWithoutDippingToSilence() {
        let steps = [
            step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67)),
            step(midiNote: 64, onset: 0.2, duration: 0.2, harmony: harmonyNotes(bass: 52, third: 68, fifth: 71)),
        ]
        let bufferLength = Int(0.4 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)
        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .harmony(.third), rate: rate)

        let boundary = Int(0.2 * rate)
        let window = track[max(0, boundary - 50)..<min(bufferLength, boundary + 50)]
        XCTAssertTrue(window.contains { abs($0) > 0.2 })
    }

    // 128절 회귀 테스트 — MelodySegmenter가 "음"으로 인식 못한 구간(숨소리/자음/저신뢰도 전환)이
    // 예전엔 완전한 무음으로 재생됐다. 멜로디는 세그먼트 재구성을 안 거치므로, 스텝 사이 미커버
    // 구간에도 원본 오디오가 그대로 남아있어야 한다.
    func testMelodyVoicePreservesAudioInGapsBetweenRecognizedSteps() {
        let steps = [
            step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: nil),
            step(midiNote: 62, onset: 0.4, duration: 0.2, harmony: nil),
        ]
        let bufferLength = Int(0.6 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)
        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .melody, rate: rate)

        // 0.2~0.4초는 두 스텝 어느 쪽에도 안 걸리는 "미인식 구간" — 원본엔 계속 소리가 있었다.
        let gapStart = Int(0.25 * rate)
        let gapEnd = Int(0.35 * rate)
        XCTAssertTrue(track[gapStart..<gapEnd].contains { abs($0) > 0.2 })
    }

    // 128절 — 멜로디는 이제 세그먼트 재구성 없이 원본을 그대로 돌려주는 패스스루라는 계약을 명시.
    func testMelodyVoiceIsIdenticalToSourceBufferWhenLengthsMatch() {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: nil)]
        let bufferLength = Int(0.2 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)

        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .melody, rate: rate)
        XCTAssertEqual(track, source)
    }

    // 129절 — 두 화음 스텝 사이에 진짜 무음/숨쉬는 구간(연결 임계값보다 먼 gap)이 있으면
    // 그 구간은 조용해야 한다(F0 곡선은 안 지워도 진폭 마스킹으로 무음 처리됨).
    func testGenuineGapBetweenNonContiguousStepsIsSilent() {
        let steps = [
            step(midiNote: 60, onset: 0.0, duration: 0.2, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67)),
            step(midiNote: 64, onset: 1.0, duration: 0.2, harmony: harmonyNotes(bass: 52, third: 68, fifth: 71)),
        ]
        let bufferLength = Int(1.2 * rate)
        let source = sineWave(frequency: 261.63, sampleCount: bufferLength)
        let track = VoiceHarmonyTrackBuilder.build(melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: .harmony(.third), rate: rate)

        let gapStart = Int(0.4 * rate)
        let gapEnd = Int(0.8 * rate)
        XCTAssertTrue(track[gapStart..<gapEnd].allSatisfy { abs($0) < 0.01 })
    }

    // MARK: - 여러 성부를 한 번의 분석으로 (mixedTrack)

    private var mixFixture: (steps: [MelodyStep], source: [Float], bufferLength: Int) {
        let steps = [
            step(midiNote: 60, onset: 0.1, duration: 0.3, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67)),
            step(midiNote: 62, onset: 0.5, duration: 0.3, harmony: harmonyNotes(bass: 50, third: 65, fifth: 69)),
        ]
        let bufferLength = Int(1.0 * rate)
        return (steps, sineWave(frequency: 261.63, sampleCount: bufferLength), bufferLength)
    }

    /// **분석을 공유해도 소리가 달라지면 안 된다.** 성부마다 따로 분석하던 걸 한 번으로 줄인
    /// 최적화(2026-08-24)라, 결과가 예전과 같은지가 이 변경의 안전 조건이다.
    func testMixedTrackMatchesIndividuallyBuiltVoices() {
        let (steps, source, bufferLength) = mixFixture
        let voices: [VoiceHarmonyTrackBuilder.Voice] = [.melody, .harmony(.bass), .harmony(.third), .harmony(.fifth)]
        let backingGain: Float = 0.65

        let mixed = VoiceHarmonyTrackBuilder.mixedTrack(
            melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength,
            voices: voices, rate: rate, backingGain: backingGain
        )

        // 예전 호출부가 하던 것 그대로 — 성부마다 build하고 화음에만 backingGain을 건 뒤 섞는다.
        let individually = AudioGain.mix(tracks: voices.map { voice in
            let track = VoiceHarmonyTrackBuilder.build(
                melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voice: voice, rate: rate
            )
            if case .melody = voice { return track }
            return track.map { $0 * backingGain }
        })

        XCTAssertEqual(mixed.count, individually.count)
        for (index, (a, b)) in zip(mixed, individually).enumerated() {
            XCTAssertEqual(a, b, accuracy: 1e-5, "\(index)번째 샘플이 달라졌다")
        }
    }

    func testMixedTrackMatchesBufferLength() {
        let (steps, source, bufferLength) = mixFixture
        let mixed = VoiceHarmonyTrackBuilder.mixedTrack(
            melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength,
            voices: [.melody, .harmony(.third)], rate: rate
        )
        XCTAssertEqual(mixed.count, bufferLength)
    }

    /// 멜로디만 고르면 WORLD 분석 자체가 필요 없다 — 원본이 그대로 나와야 한다(배율도 안 걸린다).
    func testMixedTrackWithMelodyOnlyReturnsSourceUnscaled() {
        let (steps, source, bufferLength) = mixFixture
        let mixed = VoiceHarmonyTrackBuilder.mixedTrack(
            melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength,
            voices: [.melody], rate: rate
        )
        XCTAssertEqual(mixed.count, bufferLength)
        for (index, (a, b)) in zip(mixed, source).enumerated() {
            XCTAssertEqual(a, b, accuracy: 1e-6, "\(index)번째 샘플이 원본과 다르다")
        }
    }

    func testMixedTrackWithNoVoicesIsEmpty() {
        let (steps, source, bufferLength) = mixFixture
        XCTAssertTrue(VoiceHarmonyTrackBuilder.mixedTrack(
            melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voices: [], rate: rate
        ).isEmpty)
    }

    // MARK: - 스테레오 믹스 (145절)

    func testMixedStereoTrackKeepsBufferLengthOnBothChannels() {
        let (steps, source, bufferLength) = mixFixture
        let (left, right) = VoiceHarmonyTrackBuilder.mixedStereoTrack(
            melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength,
            voices: [.melody, .harmony(.bass), .harmony(.third), .harmony(.fifth)], rate: rate
        )
        XCTAssertEqual(left.count, bufferLength)
        XCTAssertEqual(right.count, bufferLength)
    }

    /// 이 기능의 존재 이유 자체 — 성부가 좌우로 갈렸다면 두 채널이 같을 수 없다.
    /// (모노로 합치던 예전 동작이라면 두 채널이 샘플 단위로 동일하다.)
    func testMixedStereoTrackActuallySeparatesChannels() {
        let (steps, source, bufferLength) = mixFixture
        let (left, right) = VoiceHarmonyTrackBuilder.mixedStereoTrack(
            melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength,
            voices: [.harmony(.third), .harmony(.fifth)], rate: rate
        )

        let maxDifference = zip(left, right).map { abs($0 - $1) }.max() ?? 0
        XCTAssertGreaterThan(maxDifference, 0.001, "좌우 채널이 동일하다 — 팬이 적용되지 않았다")
    }

    /// 멜로디는 리드라서 정중앙이어야 한다 — 혼자 재생하면 좌우가 같아야 한다.
    func testMixedStereoTrackKeepsMelodyCentered() {
        let (steps, source, bufferLength) = mixFixture
        let (left, right) = VoiceHarmonyTrackBuilder.mixedStereoTrack(
            melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength,
            voices: [.melody], rate: rate
        )
        for (index, (l, r)) in zip(left, right).enumerated() {
            XCTAssertEqual(l, r, accuracy: 1e-6, "\(index)번째 샘플에서 멜로디가 중앙이 아니다")
        }
    }

    // MARK: - 휴머나이즈 (145절)

    /// 성부마다 발성 시작이 조금씩 어긋나야 "여러 명"으로 들린다 — 트랙 맨 앞에 그 성부의
    /// 오프셋만큼 무음이 생겨야 한다.
    func testHarmonyVoiceIsDelayedByItsOnsetOffset() {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.4, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67))]
        let bufferLength = Int(0.4 * rate)
        let source = sineWave(frequency: NoteNameConverter.frequency(forMIDINote: 60), sampleCount: bufferLength)

        let track = VoiceHarmonyTrackBuilder.build(
            melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength,
            voice: .harmony(.fifth), rate: rate, fadeDuration: 0
        )

        let offsetSamples = Int(ChordGenerator.Interval.fifth.onsetOffsetSeconds * rate)
        XCTAssertGreaterThan(offsetSamples, 0, "테스트 전제: 5도에 오프셋이 있어야 한다")
        for i in 0..<offsetSamples {
            XCTAssertEqual(track[i], 0, accuracy: 1e-6, "\(i)번째 샘플 — 지연 구간이 무음이 아니다")
        }
        XCTAssertEqual(track.count, bufferLength, "지연을 줘도 길이는 보존돼야 한다")
    }

    /// 성부끼리 시작 지점이 실제로 달라야 한다(둘 다 같은 지연이면 여전히 클론이다).
    func testHarmonyVoicesStartAtDifferentTimes() {
        let steps = [step(midiNote: 60, onset: 0.0, duration: 0.4, harmony: harmonyNotes(bass: 48, third: 64, fifth: 67))]
        let bufferLength = Int(0.4 * rate)
        let source = sineWave(frequency: NoteNameConverter.frequency(forMIDINote: 60), sampleCount: bufferLength)

        func firstAudibleIndex(_ voice: VoiceHarmonyTrackBuilder.Voice) -> Int? {
            let track = VoiceHarmonyTrackBuilder.build(
                melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength,
                voice: voice, rate: rate, fadeDuration: 0
            )
            return track.firstIndex { abs($0) > 0.0001 }
        }

        let third = firstAudibleIndex(.harmony(.third))
        let fifth = firstAudibleIndex(.harmony(.fifth))
        XCTAssertNotNil(third)
        XCTAssertNotNil(fifth)
        XCTAssertNotEqual(third, fifth, "3도와 5도가 정확히 같은 시각에 시작한다 — 어긋남이 없다")
    }

    func testMixedStereoTrackWithNoVoicesIsEmpty() {
        let (steps, source, bufferLength) = mixFixture
        let (left, right) = VoiceHarmonyTrackBuilder.mixedStereoTrack(
            melodySteps: steps, sourceBuffer: source, bufferLength: bufferLength, voices: [], rate: rate
        )
        XCTAssertTrue(left.isEmpty)
        XCTAssertTrue(right.isEmpty)
    }
    // MARK: - 떨림이 만든 짧은 구간 병합 (153절)

    private func seg(_ start: Int, _ end: Int, _ ratio: Double) -> VoiceHarmonyTrackBuilder.Segment {
        VoiceHarmonyTrackBuilder.Segment(start: start, end: end, pitchRatio: ratio)
    }

    /// 이 기능의 존재 이유 — 반음 떨림이 잘못 채보되면 그 짧은 구간만 화음 비율이 달라져
    /// 화음이 반음 튄다. 짧은 구간은 앞 구간의 비율을 그대로 이어받아야 한다.
    func testBriefSegmentInheritsThePreviousRatioInsteadOfItsOwn() {
        let rate = 44100.0
        let long = seg(0, Int(0.60 * rate), 1.25)
        let wobble = seg(Int(0.60 * rate), Int(0.70 * rate), 1.18)   // 0.10초짜리 떨림
        let next = seg(Int(0.70 * rate), Int(1.30 * rate), 1.25)

        let merged = VoiceHarmonyTrackBuilder.mergeBriefSegments([long, wobble, next], rate: rate)

        XCTAssertEqual(merged.count, 2, "떨림 구간이 앞 구간에 흡수돼야 한다")
        XCTAssertEqual(merged[0].pitchRatio, 1.25, "앞 구간의 비율이 유지돼야 한다")
        XCTAssertEqual(merged[0].end, wobble.end, "앞 구간이 떨림 구간 끝까지 늘어나야 한다")
    }

    /// **무음으로 갈라진 짧은 구간은 붙이지 않는다** — 붙이면 숨 쉬는 구간까지 화음이 울린다.
    func testBriefSegmentSeparatedBySilenceIsNotMerged() {
        let rate = 44100.0
        let long = seg(0, Int(0.60 * rate), 1.25)
        let afterBreath = seg(Int(1.50 * rate), Int(1.65 * rate), 1.18)  // 0.9초 무음 뒤 짧은 음

        let merged = VoiceHarmonyTrackBuilder.mergeBriefSegments([long, afterBreath], rate: rate)

        XCTAssertEqual(merged, [long, afterBreath], "무음을 사이에 둔 구간은 그대로 남아야 한다")
    }

    /// 맨 앞 구간이 짧으면 붙일 앞이 없다 — 뒤 구간이 흡수하고 뒤 구간의 비율을 쓴다.
    func testLeadingBriefSegmentIsAbsorbedByTheFollowingOne() {
        let rate = 44100.0
        let leading = seg(0, Int(0.10 * rate), 1.18)
        let main = seg(Int(0.10 * rate), Int(0.90 * rate), 1.25)

        let merged = VoiceHarmonyTrackBuilder.mergeBriefSegments([leading, main], rate: rate)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start, 0)
        XCTAssertEqual(merged[0].end, main.end)
        XCTAssertEqual(merged[0].pitchRatio, 1.25)
    }

    /// 충분히 긴 구간들은 하나도 안 건드린다.
    func testLongSegmentsAreLeftUntouched() {
        let rate = 44100.0
        let a = seg(0, Int(0.50 * rate), 1.20)
        let b = seg(Int(0.50 * rate), Int(1.00 * rate), 1.30)

        XCTAssertEqual(VoiceHarmonyTrackBuilder.mergeBriefSegments([a, b], rate: rate), [a, b])
    }

}
