import XCTest
@testable import HarmonyUp

final class MelodySegmenterTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func sineWave(midiNote: Int, sampleCount: Int) -> [Float] {
        let frequency = NoteNameConverter.frequency(forMIDINote: midiNote)
        return (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    private func silence(sampleCount: Int) -> [Float] {
        Array(repeating: 0, count: sampleCount)
    }

    /// 기준 음 주변에서 주파수가 오르내리는(비브라토) 사인파. 순간 주파수를 적분해서 위상을 쌓는
    /// 방식이라, 단순히 sin(base*t)에 진폭 변조를 곱하는 것과 달리 실제로 주파수 자체가 흔들린다.
    private func vibratoWave(midiNote: Int, centsAmplitude: Double, vibratoRateHz: Double, sampleCount: Int) -> [Float] {
        let baseFrequency = NoteNameConverter.frequency(forMIDINote: midiNote)
        var phase = 0.0
        var samples: [Float] = []
        samples.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let centsOffset = centsAmplitude * sin(2.0 * Double.pi * vibratoRateHz * Double(i) / sampleRate)
            let instantaneousFrequency = baseFrequency * pow(2.0, centsOffset / 1200.0)
            phase += 2.0 * Double.pi * instantaneousFrequency / sampleRate
            samples.append(Float(sin(phase)))
        }
        return samples
    }

    func testSingleSustainedNote() {
        let samples = sineWave(midiNote: 69, sampleCount: 8192) // A4

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.midiNote, 69)
        XCTAssertGreaterThan(notes.first?.duration ?? 0, 0.1)
    }

    func testTwoAdjacentNotesWithNoGapSplitOnPitchChange() {
        // 무음 구간 없이 바로 이어붙인 두 음 — 피치 변화만으로 경계를 잡아내야 한다.
        let samples = sineWave(midiNote: 60, sampleCount: 8192) + sineWave(midiNote: 64, sampleCount: 8192)

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(notes.map(\.midiNote), [60, 64])
        // 두 번째 음의 시작 시각이 대략 첫 음 길이(8192샘플 ≈ 0.186초) 근처여야 한다.
        XCTAssertEqual(notes[1].onsetTime, 8192.0 / sampleRate, accuracy: 0.05)
    }

    func testNotesSeparatedBySilenceSplitOnVADBoundary() {
        let samples = sineWave(midiNote: 60, sampleCount: 8192)
            + silence(sampleCount: 4096)
            + sineWave(midiNote: 64, sampleCount: 8192)

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(notes.map(\.midiNote), [60, 64])
    }

    func testShortBlipBelowMinimumDurationIsDropped() {
        // 분석 윈도우(2048샘플 ≈ 0.046초)보다 뚜렷이 짧은 blip(약 0.02초)이 무음 사이에 끼어 있어도
        // 결과에 나타나면 안 된다 — 숨소리/잡음성 튐을 걸러내는 목적. blip이 윈도우보다 길면
        // 여러 윈도우에 걸쳐 "스며들어" 실제보다 길게 잡힐 수 있어서, 일부러 윈도우보다 짧게 잡았다.
        let blipSampleCount = Int(0.02 * sampleRate)
        let samples = silence(sampleCount: 4096)
            + sineWave(midiNote: 64, sampleCount: blipSampleCount)
            + silence(sampleCount: 4096)

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertFalse(notes.map(\.midiNote).contains(64))
    }

    func testVibratoCollapsesToOneNote() {
        // 기준음 주변 ±30cent로 흔들리는 비브라토 — 반음(100cent) 안쪽이라 반올림한 MIDI 노트
        // 자체는 안 바뀌어야 하고, 그러면 여러 음으로 쪼개지지 않고 한 음으로 이어져야 한다.
        let samples = vibratoWave(midiNote: 69, centsAmplitude: 30, vibratoRateHz: 5.5, sampleCount: 16384)

        let notes = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.midiNote, 69)
    }

    func testEmptyBufferReturnsNoNotes() {
        XCTAssertTrue(MelodySegmenter.segment(samples: [], sampleRate: sampleRate).isEmpty)
    }

    func testBufferShorterThanWindowReturnsNoNotes() {
        let samples = sineWave(midiNote: 69, sampleCount: 512)
        XCTAssertTrue(MelodySegmenter.segment(samples: samples, sampleRate: sampleRate).isEmpty)
    }

    // MARK: - 중앙값 필터(medianFiltered)

    func testMedianFilterSmoothsSingleFrameOutlier() {
        // 순간적으로 옥타브 위로 튄 프레임 하나(비브라토/옥타브 오검출을 흉내) — 앞뒤 값에
        // 묻혀서 사라져야 한다.
        let notes: [Int?] = [60, 60, 72, 60, 60]
        XCTAssertEqual(MelodySegmenter.medianFiltered(midiNotes: notes, radius: 1), [60, 60, 60, 60, 60])
    }

    func testMedianFilterPreservesSilenceGaps() {
        // 무음(nil) 자리는 이웃 음의 중앙값 계산에 섞이지 않고 그대로 nil로 남아야 한다 —
        // 안 그러면 음 경계가 무뎌진다.
        let notes: [Int?] = [60, 60, nil, nil, 64, 64]
        let filtered = MelodySegmenter.medianFiltered(midiNotes: notes, radius: 1)
        XCTAssertNil(filtered[2])
        XCTAssertNil(filtered[3])
        XCTAssertEqual(filtered[0], 60)
        XCTAssertEqual(filtered[5], 64)
    }

    func testMedianFilterWithZeroRadiusReturnsUnchanged() {
        let notes: [Int?] = [60, 72, 60]
        XCTAssertEqual(MelodySegmenter.medianFiltered(midiNotes: notes, radius: 0), notes)
    }

    func testMedianFilterOnEmptyArrayReturnsEmpty() {
        XCTAssertTrue(MelodySegmenter.medianFiltered(midiNotes: [], radius: 1).isEmpty)
    }

    func testMedianFilterAtBoundaryUsesAvailableNeighborsOnly() {
        // 배열 맨 앞이라 왼쪽 이웃이 없는 경우 — 있는 이웃(자신+오른쪽)만으로 중앙값을 내야 하고,
        // 범위를 벗어나 크래시가 나면 안 된다. 정렬한 [60, 72]는 원소가 짝수 개라 뒤쪽(index 1)인
        // 72가 중앙값이 된다(medianFiltered 구현이 뒤쪽을 택하는 것과 일치).
        let notes: [Int?] = [72, 60, 60]
        let filtered = MelodySegmenter.medianFiltered(midiNotes: notes, radius: 1)
        XCTAssertEqual(filtered[0], 72)
    }

    // MARK: - 짧은 과도구간 흡수(absorbShortRuns) — 실기기 로그로 실측한 실제 패턴 기반

    func testAbsorbShortRunsMergesPortamentoIntoEquidistantPreviousNeighbor() {
        // 실기기 로그 실측: "도 레 미 파 솔"을 불렀을 때 레(D3)에서 미(E3)로 넘어가는 사이
        // 반음 위(D#3) 슬라이드가 0.09초나 지속돼 중앙값 필터로도 안 걸러지고 독립된 음표로
        // 남았다. D#3는 D3/E3 양쪽에서 정확히 반음씩 떨어져 있어(거리 동률) 이전 음(D3)으로
        // 합쳐져야 한다.
        let notes = [
            MelodySegmenter.SegmentedNote(midiNote: 62, onsetTime: 0.0, duration: 0.43, averageConfidence: 0.9),   // D3
            MelodySegmenter.SegmentedNote(midiNote: 63, onsetTime: 0.43, duration: 0.09, averageConfidence: 0.5),  // D#3, 과도구간
            MelodySegmenter.SegmentedNote(midiNote: 64, onsetTime: 0.52, duration: 0.33, averageConfidence: 0.9)   // E3
        ]

        let result = MelodySegmenter.absorbShortRuns(notes, minimumDuration: 0.18)

        XCTAssertEqual(result.map(\.midiNote), [62, 64])
        // D3가 D#3의 구간까지 흡수해서 늘어나야 한다(끝이 원래 D#3의 끝과 같아짐).
        XCTAssertEqual(result[0].duration, 0.52, accuracy: 0.001)
        XCTAssertEqual(result[0].onsetTime, 0.0, accuracy: 0.001)
    }

    func testAbsorbShortRunsCascadesFlickeringNeighborsIntoOneNote() {
        // 실기기 로그 실측: 솔(G3)을 길게 부를 때 반음 경계(G3/G#3) 바로 근처라 YIN 반올림이
        // 여러 번 왔다갔다(G3 G#3 G3 G#3 G3...)해서 짧은 음표 여러 개로 쪼개졌다. 전부 하나의
        // 음(G3 계열)으로 수렴해야 한다 — 반복적으로 가장 짧은 후보부터 흡수해나가는 게 이걸
        // 처리할 수 있는지 확인.
        let notes = [
            MelodySegmenter.SegmentedNote(midiNote: 55, onsetTime: 0.0, duration: 0.10, averageConfidence: 0.6),  // G3
            MelodySegmenter.SegmentedNote(midiNote: 56, onsetTime: 0.10, duration: 0.09, averageConfidence: 0.5), // G#3
            MelodySegmenter.SegmentedNote(midiNote: 55, onsetTime: 0.19, duration: 0.10, averageConfidence: 0.6), // G3
            MelodySegmenter.SegmentedNote(midiNote: 55, onsetTime: 0.29, duration: 0.12, averageConfidence: 0.6), // G3
            MelodySegmenter.SegmentedNote(midiNote: 56, onsetTime: 0.41, duration: 0.15, averageConfidence: 0.5)  // G#3
        ]

        let result = MelodySegmenter.absorbShortRuns(notes, minimumDuration: 0.18)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].onsetTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(result[0].duration, 0.56, accuracy: 0.001) // 전체 구간(0.0~0.56)을 다 흡수
    }

    func testAbsorbShortRunsKeepsOrphanNoteWithNoNeighbors() {
        // 118절: "흡수할 무음-없는 이웃이 없다"는 이제 "버릴 이유"가 아니라 "짧아도 진짜 음일
        // 가능성이 높다"는 신호로 바뀌었다 — 녹음 전체가 짧은 음 하나뿐이어도(이웃 자체가
        // 없음) 그대로 남긴다.
        let notes = [MelodySegmenter.SegmentedNote(midiNote: 64, onsetTime: 0.0, duration: 0.05, averageConfidence: 0.5)]

        XCTAssertEqual(MelodySegmenter.absorbShortRuns(notes, minimumDuration: 0.18), notes)
    }

    func testAbsorbShortRunsKeepsShortNoteIsolatedBySilenceOnBothSides() {
        // 118절 실기기 로그 실측: 빠르게 부른 "도레미파솔라시도"에서 "파"(F3, 0.12초)가 앞뒤로
        // 뚜렷한 무음 간격(직전 E3과 34ms, 직후 F#3 잡음과 93ms)을 두고 독립적으로 불렸는데도
        // 짧다는 이유만으로 흡수돼 사라졌다 — 무음으로 갈라져 있으면 짧아도 흡수하지 않고
        // 그대로 남아야 한다.
        let notes = [
            MelodySegmenter.SegmentedNote(midiNote: 64, onsetTime: 0.0, duration: 0.30, averageConfidence: 0.9),   // E3
            MelodySegmenter.SegmentedNote(midiNote: 65, onsetTime: 0.334, duration: 0.12, averageConfidence: 0.97), // F3, 앞뒤 무음으로 고립
            MelodySegmenter.SegmentedNote(midiNote: 66, onsetTime: 0.547, duration: 0.30, averageConfidence: 0.9)   // F#3(잡음)
        ]

        let result = MelodySegmenter.absorbShortRuns(notes, minimumDuration: 0.18)

        XCTAssertEqual(result.map(\.midiNote), [64, 65, 66])
        XCTAssertEqual(result[1].duration, 0.12, accuracy: 0.001) // F3가 흡수되지 않고 그대로 유지
    }

    func testAbsorbShortRunsDoesNotMergeRepeatedNoteAcrossRealSilenceGap() {
        // 118절 실기기 로그 실측: "도"를 여러 번 따로(무음 간격 69~232ms) 불러도, 각 반복이
        // 개별적으로 0.18초보다 짧으면 예전엔 서로 흡수돼 하나의 "도"로 뭉개졌다 — 무음
        // 간격이 이 정도로 뚜렷하면(허용 오차 0.02초를 훨씬 넘음) 절대 흡수하지 않아야 한다.
        let notes = [
            MelodySegmenter.SegmentedNote(midiNote: 48, onsetTime: 0.0, duration: 0.14, averageConfidence: 0.97),   // 도(1차)
            MelodySegmenter.SegmentedNote(midiNote: 48, onsetTime: 0.209, duration: 0.13, averageConfidence: 0.97), // 도(2차), 69ms 간격
            MelodySegmenter.SegmentedNote(midiNote: 48, onsetTime: 0.571, duration: 0.15, averageConfidence: 0.95)  // 도(3차), 232ms 간격
        ]

        let result = MelodySegmenter.absorbShortRuns(notes, minimumDuration: 0.18)

        XCTAssertEqual(result.count, 3, "무음으로 뚜렷이 갈라진 반복음은 흡수되지 않고 각각 남아야 한다")
    }

    func testAbsorbShortRunsKeepsShortNoteEvenWhenContiguousIfWholeToneAway() {
        // 119절 실기기 로그 실측: 빠르게 부른 "도레미파"에서 "미"(E3, 0.09초)가 앞의 "레"(D3)와는
        // 무음 없이 바로 이어지고(isContiguous 통과, 온음 차이라 포르타멘토 아님), 뒤의
        // "파"(F3)와는 뚜렷한 무음 간격(80ms)으로 갈라져 있었다. 지금까지 확인된 진짜
        // 포르타멘토(D3->D#3->E3, G3<->G#3, C3<->B2)는 전부 이웃과 반음 차이였다 — 온음(2
        // semitone, 레->미) 떨어진 짧은 음은 무음이 없어도 포르타멘토가 아니라 빠르게 스쳐간
        // 진짜 음일 가능성이 높으므로, 양쪽 다 흡수 조건(무음 없음 + 반음 이내)을 못 채우면
        // 흡수하지 않고 그대로 남아야 한다.
        let notes = [
            MelodySegmenter.SegmentedNote(midiNote: 62, onsetTime: 0.0, duration: 0.30, averageConfidence: 0.9),  // D3
            MelodySegmenter.SegmentedNote(midiNote: 64, onsetTime: 0.30, duration: 0.09, averageConfidence: 0.9), // E3, 앞과는 무음 없이 붙어있지만 온음 차이
            MelodySegmenter.SegmentedNote(midiNote: 65, onsetTime: 0.47, duration: 0.30, averageConfidence: 0.9)  // F3, 80ms 무음 간격 뒤
        ]

        let result = MelodySegmenter.absorbShortRuns(notes, minimumDuration: 0.18)

        XCTAssertEqual(result.map(\.midiNote), [62, 64, 65], "온음 떨어진 짧은 음은 무음이 없어도 흡수되면 안 된다")
    }

    func testAbsorbShortRunsKeepsNotesAlreadyAboveThreshold() {
        let notes = [
            MelodySegmenter.SegmentedNote(midiNote: 60, onsetTime: 0.0, duration: 0.3, averageConfidence: 0.9),
            MelodySegmenter.SegmentedNote(midiNote: 62, onsetTime: 0.3, duration: 0.3, averageConfidence: 0.9)
        ]

        XCTAssertEqual(MelodySegmenter.absorbShortRuns(notes, minimumDuration: 0.18), notes)
    }

    // MARK: - 흡수 이후 동일 음높이 병합(mergeAdjacentSamePitch)

    func testMergeAdjacentSamePitchCombinesTwins() {
        let notes = [
            MelodySegmenter.SegmentedNote(midiNote: 48, onsetTime: 0.0, duration: 0.3, averageConfidence: 0.8),
            MelodySegmenter.SegmentedNote(midiNote: 48, onsetTime: 0.3, duration: 0.25, averageConfidence: 0.8)
        ]

        let result = MelodySegmenter.mergeAdjacentSamePitch(notes)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].midiNote, 48)
        XCTAssertEqual(result[0].onsetTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(result[0].duration, 0.55, accuracy: 0.001)
    }

    func testMergeAdjacentSamePitchLeavesDifferentPitchesAlone() {
        let notes = [
            MelodySegmenter.SegmentedNote(midiNote: 48, onsetTime: 0.0, duration: 0.3, averageConfidence: 0.8),
            MelodySegmenter.SegmentedNote(midiNote: 50, onsetTime: 0.3, duration: 0.3, averageConfidence: 0.8)
        ]

        XCTAssertEqual(MelodySegmenter.mergeAdjacentSamePitch(notes), notes)
    }

    func testMergeAdjacentSamePitchDoesNotMergeAcrossRealSilenceGapUnder180ms() {
        // 119절 실기기 로그 실측: "도도솔솔라라솔"에서 absorbShortRuns(118절)는 반복된
        // "솔"들을 무음 간격(127ms) 덕에 올바르게 별개로 남겼는데, 이 병합 단계가 예전 임계값
        // (0.18초)으로는 127ms < 180ms라서 다시 하나로 합쳐버렸다. 이제 이 단계도
        // contiguousGapTolerance(0.02초) 기준을 쓰므로, 20ms보다 뚜렷한 무음 간격이 있으면
        // 같은 음높이라도 합치면 안 된다.
        let notes = [
            MelodySegmenter.SegmentedNote(midiNote: 56, onsetTime: 0.0, duration: 0.41, averageConfidence: 0.98), // G#3
            MelodySegmenter.SegmentedNote(midiNote: 56, onsetTime: 0.537, duration: 0.58, averageConfidence: 0.98) // G#3, 127ms 간격
        ]

        let result = MelodySegmenter.mergeAdjacentSamePitch(notes)

        XCTAssertEqual(result.count, 2, "180ms보다는 짧아도 실제 무음 간격이면 병합하면 안 된다")
    }

    func testAbsorbThenMergeReproducesRealWorldGlitchInsideSustainedNote() {
        // 실기기 로그 실측: "도"(C3)를 부르는 도중 순간적으로 옥타브 아래(B2)로 3윈도우(~0.07초)
        // 튀었다가 다시 C3로 돌아온 경우 — "C3, B2(짧음), C3" 세 후보가 만들어지는데, B2를
        // 앞쪽 C3로 흡수하고 나면 "C3, C3"가 나란히 남는다. 이걸 다시 하나로 합쳐야 사용자가
        // 실제로 부른 "도 하나"와 결과가 일치한다.
        let candidates = [
            MelodySegmenter.SegmentedNote(midiNote: 48, onsetTime: 0.0, duration: 0.30, averageConfidence: 0.8),  // C3
            MelodySegmenter.SegmentedNote(midiNote: 47, onsetTime: 0.30, duration: 0.07, averageConfidence: 0.4), // B2, 잡음
            MelodySegmenter.SegmentedNote(midiNote: 48, onsetTime: 0.37, duration: 0.30, averageConfidence: 0.8)  // C3
        ]

        let result = MelodySegmenter.mergeAdjacentSamePitch(
            MelodySegmenter.absorbShortRuns(candidates, minimumDuration: 0.18)
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].midiNote, 48)
        XCTAssertEqual(result[0].onsetTime, 0.0, accuracy: 0.001)
        XCTAssertEqual(result[0].duration, 0.67, accuracy: 0.001)
    }

    // MARK: - 통합: MelodySegmenter -> RhythmQuantizer/ChordGenerator로 이어지는지

    func testFilteredNoteSequenceFlowsIntoRhythmQuantizerAndChordGenerator() {
        // 무음 간격을 두고 C-D-E-F(온음계 순차 진행)를 부른 것을 흉내낸다.
        let melodyMIDINotes = [60, 62, 64, 65]
        var samples: [Float] = []
        for midiNote in melodyMIDINotes {
            samples += sineWave(midiNote: midiNote, sampleCount: 8192)
            samples += silence(sampleCount: 2048)
        }

        let segmented = MelodySegmenter.segment(samples: samples, sampleRate: sampleRate)
        XCTAssertEqual(segmented.map(\.midiNote), melodyMIDINotes)

        // RhythmQuantizer로 실제 길이(초)가 그대로 전달되는지 — 개수가 어긋나면 이후 성부별
        // 정렬(measureBreaks 공유)이 깨진다.
        let quantized = RhythmQuantizer.quantize(durations: segmented.map(\.duration))
        XCTAssertEqual(quantized.count, segmented.count)

        // KeyDetector -> ChordGenerator로 화음까지 이어지는지.
        let weightedNotes = segmented.map {
            KeyDetector.WeightedNote(pitchClass: $0.midiNote % 12, duration: $0.duration)
        }
        guard let key = KeyDetector.detectKey(notes: weightedNotes) else {
            XCTFail("조성 판별 실패")
            return
        }
        let harmonized = ChordGenerator.harmonizeSequence(
            melodyNotes: segmented.map { ($0.midiNote, $0.duration) },
            key: key
        )
        XCTAssertEqual(harmonized.count, segmented.count)
        XCTAssertNotNil(harmonized.first ?? nil) // 첫 음(도, 근음)엔 화음이 배정돼야 한다
    }
}
