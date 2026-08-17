import Foundation

/// 녹음이 끝난 뒤 통째로 들어온 오디오 버퍼를, "부른 음 하나하나"(음높이+시작시간+길이)로 잘라낸다.
/// `MelodySession`은 실시간 프레임을 하나씩만 받는 구조라 이 배치(다 녹음된 걸 한 번에 분석) 방식엔
/// 안 맞는다 — 이 타입이 그 자리를 채우는 새 배치 전용 분석기다. 조성 판별(`KeyDetector`)과 화음 생성
/// (`ChordGenerator`)은 이미 순수 함수라 이 타입의 출력을 그대로 받아 재사용할 수 있다.
enum MelodySegmenter {

    struct SegmentedNote: Equatable {
        let midiNote: Int
        let onsetTime: Double       // 녹음 시작 기준 초
        let duration: Double        // 초
        let averageConfidence: Double
    }

    struct Configuration {
        // 기존 실시간 파이프라인(AudioCapture)이 이미 80Hz(남성 저음)까지 안정적으로 검출한다고
        // 검증해둔 것과 같은 윈도우 크기를 그대로 가져다 쓴다 — 새로 튜닝하지 않는다.
        var windowSize: Int = 2048
        // 윈도우를 75% 겹치게(홉 = 윈도우/4) 훑는다 — 실시간 파이프라인은 윈도우 하나당 프레임
        // 하나(약 46ms 간격)만 봤지만, 여기서는 "음이 정확히 언제 시작했는지"가 중요해서
        // 홉을 훨씬 촘촘하게(약 11.6ms) 잡아 온셋 타이밍 정밀도를 높인다.
        var hop: Int = 512
        // 같은 음(반올림한 MIDI 노트)이 이 윈도우 개수만큼 연속돼야 "진짜 이 음"으로 확정한다 —
        // 실시간 캡처의 captureStreakRequired(3프레임 디바운스)와 같은 원리를 윈도우 단위로 옮긴 것.
        // 노이즈성 윈도우 한두 개 때문에 음이 잘못 잘리는 걸 막는다.
        var streakRequired: Int = 3
        // 이보다 짧게 지속된 구간은 "진짜 새 음"이 아니라 인접 음으로 흡수 병합한다(초 단위,
        // absorbShortRuns 참고). 원래 0.08이었는데, 실기기 로그로 실측해보니 포르타멘토/반음
        // 경계 떨림 구간이 0.09~0.15초까지도 지속되는 걸 확인해서 0.18로 올렸다 — 실제로 부른
        // 음(0.2초 이상)은 이 값보다 훨씬 길어서 안전하게 구분된다.
        var minimumNoteDuration: Double = 0.18
        // 중앙값 필터의 반경 — 1이면 앞뒤 1윈도우씩 총 3윈도우, 2면 5윈도우를 보고 중앙값을 낸다.
        // 순간적인 옥타브 도약이나 비브라토가 반음 경계를 살짝 넘나들며 반올림 MIDI 노트가
        // 프레임 하나짜리로 튀는 잔떨림을 완만하게 다듬는 목적. 너무 크게 잡으면(예: 4~5) 실제로
        // 짧게 지나가는 음까지 뭉갤 수 있어서 기본값은 보수적으로 3윈도우(약 35ms)로 잡았다.
        var medianFilterRadius: Int = 1
        var yinConfiguration: YINPitchDetector.Configuration = .default
        var vadConfiguration: VoiceActivityDetector.Configuration = .default

        static let `default` = Configuration()
    }

    static func segment(samples: [Float], sampleRate: Double, configuration: Configuration = .default) -> [SegmentedNote] {
        guard samples.count >= configuration.windowSize, sampleRate > 0 else { return [] }

        let windows = analyzeWindows(samples: samples, sampleRate: sampleRate, configuration: configuration)
        guard !windows.isEmpty else { return [] }
        #if DEBUG
        logStage("1단계 원본(YIN+VAD 직후)", windows.map(\.midiNote))
        #endif

        // 중앙값 필터 -> 디바운스 -> 런랭스 인코딩, 세 단계로 나누면 각 단계를 따로 검증하기 쉽다.
        // 중앙값 필터를 디바운스보다 먼저 적용하는 이유: 디바운스는 "연속으로 같은 값"만 확정하므로,
        // 중앙값 필터가 먼저 튀는 프레임을 눌러줘야 디바운스가 볼 스트릭이 애초에 더 깨끗해진다.
        let smoothed = medianFiltered(midiNotes: windows.map(\.midiNote), radius: configuration.medianFilterRadius)
        #if DEBUG
        logStage("2단계 중앙값 필터 후", smoothed)
        #endif

        let debounced = debounce(smoothed, streakRequired: configuration.streakRequired)
        #if DEBUG
        logStage("3단계 디바운스 후", debounced)
        #endif

        let notes = runLengthEncode(
            debounced,
            confidences: windows.map(\.confidence),
            hop: configuration.hop,
            windowSize: configuration.windowSize,
            sampleRate: sampleRate,
            minimumDuration: configuration.minimumNoteDuration
        )
        #if DEBUG
        let noteList = notes.map { note -> String in
            let name = NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: note.midiNote))?.noteName ?? "?"
            return "\(name)(\(String(format: "%.2fs", note.duration)))"
        }.joined(separator: ", ")
        print("[MelodySegmenter] 4단계 최종 \(notes.count)개 음표: \(noteList)")
        #endif

        return notes
    }

    #if DEBUG
    /// 디버그 전용 — 같은 값이 연속되는 구간을 "이름×횟수"로 압축해서 찍는다(윈도우 하나하나를
    /// 그대로 찍으면 수백 줄이라 읽기 힘들다). 예: "C3×12 D3×1 C3×8" 처럼 나오면 중간의
    /// "D3×1"이 순간적으로 튄 잡음이라는 게 한눈에 보인다 — "부른 음보다 악보에 음표가 더 많이
    /// 나온다"는 문제를 이 단계별 로그로 어느 단계(원본/중앙값 필터/디바운스)에서 걸러지고
    /// 있는지, 혹은 안 걸러지고 있는지 실측으로 추적하기 위해 추가했다.
    private static func logStage(_ label: String, _ values: [Int?]) {
        guard !values.isEmpty else {
            print("[MelodySegmenter] \(label): (빈 배열)")
            return
        }
        var summary: [String] = []
        var current = values[0]
        var count = 1
        for value in values.dropFirst() {
            if value == current {
                count += 1
            } else {
                summary.append(runLabel(current, count))
                current = value
                count = 1
            }
        }
        summary.append(runLabel(current, count))
        print("[MelodySegmenter] \(label): " + summary.joined(separator: " "))
    }

    private static func runLabel(_ value: Int?, _ count: Int) -> String {
        guard let value else { return "무음×\(count)" }
        let name = NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: value))?.noteName ?? "?"
        return "\(name)×\(count)"
    }
    #endif

    // MARK: - 1단계: 윈도우마다 VAD -> YIN -> 반올림한 MIDI 노트

    private struct WindowAnalysis {
        let midiNote: Int?    // nil = 무음이거나 피치를 못 찾음
        let confidence: Double
    }

    private static func analyzeWindows(samples: [Float], sampleRate: Double, configuration: Configuration) -> [WindowAnalysis] {
        var results: [WindowAnalysis] = []
        var start = 0
        while start + configuration.windowSize <= samples.count {
            let window = Array(samples[start..<(start + configuration.windowSize)])

            if VoiceActivityDetector.isVoiceActive(samples: window, configuration: configuration.vadConfiguration),
               let candidate = YINPitchDetector.detectPitch(
                   samples: window, sampleRate: sampleRate, configuration: configuration.yinConfiguration
               ).first {
                let midiNote = Int(NoteNameConverter.exactMIDINote(forFrequency: candidate.frequency).rounded())
                results.append(WindowAnalysis(midiNote: midiNote, confidence: candidate.confidence))
            } else {
                results.append(WindowAnalysis(midiNote: nil, confidence: 0))
            }
            start += configuration.hop
        }
        return results
    }

    // MARK: - 2단계: 중앙값 필터

    /// 반올림된 MIDI 노트 스트림에서, 순간적으로 튀는 값(옥타브 도약 잔여 오류, 비브라토가
    /// 반음 경계를 살짝 넘나드는 잔떨림)을 주변 프레임들의 중앙값으로 완화한다. nil(무음/미검출)인
    /// 자리는 그대로 nil로 둔다 — 무음 구간을 이웃 음의 중앙값 계산에 섞으면 음 경계가 무뎌지므로,
    /// 값이 있는 이웃끼리만 모아서 중앙값을 낸다.
    static func medianFiltered(midiNotes: [Int?], radius: Int) -> [Int?] {
        guard radius > 0, !midiNotes.isEmpty else { return midiNotes }

        return midiNotes.indices.map { i -> Int? in
            guard midiNotes[i] != nil else { return nil }
            let lowerBound = max(0, i - radius)
            let upperBound = min(midiNotes.count - 1, i + radius)
            let neighborhood = midiNotes[lowerBound...upperBound].compactMap { $0 }.sorted()
            guard !neighborhood.isEmpty else { return midiNotes[i] }
            return neighborhood[neighborhood.count / 2]
        }
    }

    // MARK: - 3단계: 디바운스

    /// 같은 값이 `streakRequired`번 연속 나와야 "확정"되고, 그 전까지는(스트릭이 덜 찼거나 값이
    /// 막 바뀐 과도구간) 미확정(nil)으로 취급한다. 비브라토처럼 반음 근처에서 살짝살짝 흔들리는
    /// 소리도, 반올림된 MIDI 노트 자체가 안 바뀌는 한 한 음으로 계속 이어진다.
    private static func debounce(_ values: [Int?], streakRequired: Int) -> [Int?] {
        guard streakRequired > 1 else { return values }

        var result = [Int?](repeating: nil, count: values.count)
        var currentValue: Int?
        var streak = 0

        for i in values.indices {
            if let v = values[i], v == currentValue {
                streak += 1
            } else {
                currentValue = values[i]
                streak = values[i] == nil ? 0 : 1
            }

            if let currentValue, streak >= streakRequired {
                for back in 0..<streakRequired {
                    result[i - back] = currentValue
                }
            }
        }
        return result
    }

    // MARK: - 4단계: 런랭스 인코딩 -> SegmentedNote

    private static func runLengthEncode(
        _ debouncedNotes: [Int?],
        confidences: [Double],
        hop: Int,
        windowSize: Int,
        sampleRate: Double,
        minimumDuration: Double
    ) -> [SegmentedNote] {
        var notes: [SegmentedNote] = []
        var runStart: Int?
        var runNote: Int?
        var runConfidences: [Double] = []

        // 여기서는 아직 minimumDuration으로 거르지 않는다 — 짧은 구간을 그냥 버리면
        // 포르타멘토/반음 경계 떨림 구간의 시간이 통째로 사라지는데, 그 시간은 사실 앞이나
        // 뒤의 "진짜 음"에 속하는 경우가 대부분이다(아래 absorbShortRuns 참고). 일단 전부
        // 후보로 만들고, 짧은 것들을 인접한 음으로 흡수하는 건 별도 단계에서 처리한다.
        func flush(endIndexExclusive: Int) {
            guard let runNote, let runStart, endIndexExclusive > runStart else { return }
            let onset = Double(runStart) * Double(hop) / sampleRate
            let lastWindowStart = Double(endIndexExclusive - 1) * Double(hop) / sampleRate
            let end = lastWindowStart + Double(windowSize) / sampleRate
            let duration = end - onset

            let averageConfidence = runConfidences.isEmpty ? 0 : runConfidences.reduce(0, +) / Double(runConfidences.count)
            notes.append(SegmentedNote(midiNote: runNote, onsetTime: onset, duration: duration, averageConfidence: averageConfidence))
        }

        for i in debouncedNotes.indices {
            if debouncedNotes[i] == runNote {
                if runNote != nil { runConfidences.append(confidences[i]) }
            } else {
                flush(endIndexExclusive: i)
                runNote = debouncedNotes[i]
                runStart = i
                runConfidences = runNote != nil ? [confidences[i]] : []
            }
        }
        flush(endIndexExclusive: debouncedNotes.count)

        #if DEBUG
        // "짧은 음은 다 흡수한다"는 지속시간 기준 하나로는 못 가르는 경우가 실측으로 나왔다
        // (진짜 짧게 부른 음과 포르타멘토 과도구간의 길이가 겹치는 사례). 신뢰도(YIN
        // 자기상관 신뢰도 평균)가 추가 단서가 되는지 확인하려고 흡수 전 후보 단계에서
        // 지속시간과 함께 찍어본다 — 과도구간은 피치가 계속 움직여서 자기상관이 덜 뚜렷하니
        // 신뢰도가 낮게 나올 거라는 가설.
        let candidateList = notes.map { note -> String in
            let name = NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: note.midiNote))?.noteName ?? "?"
            return "\(name)(\(String(format: "%.2fs", note.duration)), 신뢰도\(String(format: "%.2f", note.averageConfidence)))"
        }.joined(separator: ", ")
        print("[MelodySegmenter] 5단계 흡수 전 후보 \(notes.count)개: \(candidateList)")
        #endif

        return mergeAdjacentSamePitch(absorbShortRuns(notes, minimumDuration: minimumDuration))
    }

    // MARK: - 5단계: 짧은 과도구간을 인접 음으로 흡수

    /// 지속시간이 `minimumDuration`보다 짧은 음은 "진짜 새로 부른 음"이 아니라, 한 음에서
    /// 다음 음으로 넘어가는 과도구간(포르타멘토 슬라이드, 반음 경계 근처 비브라토 떨림)일
    /// 가능성이 훨씬 높다 — 실측(실기기 로그)으로 두 패턴을 직접 확인했다: (1) 도->레->미로
    /// 부를 때 레와 미 사이에서 반음 위(D#3) 슬라이드가 5윈도우(~90ms)나 지속돼 중앙값
    /// 필터(반경 1)로도 못 걸러진 경우, (2) 솔(G3)을 길게 부를 때 반음 경계 바로 근처라서
    /// G3/G#3가 여러 번 번갈아 나온 경우. 그냥 버리면 그 시간이 사라지고 음정 판별용
    /// 데이터도 줄어드니, 음높이가 더 가까운 이웃(앞 또는 뒤)에 흡수시켜 그 이웃의 길이를
    /// 늘리는 쪽을 택했다 — 가장 짧은 후보부터 하나씩 흡수해나가면(반복), 여러 개가 연쇄로
    /// 짧은 경우(반음 경계에서 여러 번 왕복)도 결국 하나의 안정된 음으로 수렴한다.
    static func absorbShortRuns(_ candidates: [SegmentedNote], minimumDuration: Double) -> [SegmentedNote] {
        var notes = candidates

        while let shortestIndex = notes.indices.min(by: { notes[$0].duration < notes[$1].duration }),
              notes[shortestIndex].duration < minimumDuration {
            let shortNote = notes[shortestIndex]
            let previous = shortestIndex > 0 ? notes[shortestIndex - 1] : nil
            let next = shortestIndex < notes.count - 1 ? notes[shortestIndex + 1] : nil

            guard previous != nil || next != nil else {
                // 흡수할 이웃이 아예 없다(녹음 전체가 이 음 하나뿐) — 버리는 수밖에 없다.
                notes.remove(at: shortestIndex)
                continue
            }

            // 음높이(반음 수)가 더 가까운 이웃 쪽으로 합친다 — 포르타멘토/떨림은 보통 한쪽
            // 음에 더 가깝지, 양쪽에 똑같이 걸쳐있지 않다. 둘 다 있고 거리가 같으면 이전 음으로
            // (전환 과도구간은 대개 "떠나는 음"의 꼬리에 더 가깝다는 관찰에 근거).
            let mergeIntoPrevious: Bool
            switch (previous, next) {
            case let (.some(previous), .some(next)):
                let distanceToPrevious = abs(shortNote.midiNote - previous.midiNote)
                let distanceToNext = abs(shortNote.midiNote - next.midiNote)
                mergeIntoPrevious = distanceToPrevious <= distanceToNext
            case (.some, nil):
                mergeIntoPrevious = true
            default:
                mergeIntoPrevious = false
            }

            if mergeIntoPrevious, let previous {
                let mergedEnd = shortNote.onsetTime + shortNote.duration
                notes[shortestIndex - 1] = SegmentedNote(
                    midiNote: previous.midiNote,
                    onsetTime: previous.onsetTime,
                    duration: mergedEnd - previous.onsetTime,
                    averageConfidence: previous.averageConfidence
                )
            } else if let next {
                let mergedEnd = next.onsetTime + next.duration
                notes[shortestIndex + 1] = SegmentedNote(
                    midiNote: next.midiNote,
                    onsetTime: shortNote.onsetTime,
                    duration: mergedEnd - shortNote.onsetTime,
                    averageConfidence: next.averageConfidence
                )
            }
            notes.remove(at: shortestIndex)
        }

        return notes
    }

    // MARK: - 6단계: 흡수 이후 붙어버린 동일 음높이 병합

    /// `absorbShortRuns`가 짧은 과도구간을 이웃으로 흡수하고 나면, 그 과도구간을 사이에 두고
    /// 있던 두 이웃이 서로 같은 음높이인 경우 바로 옆에 붙게 된다 — 예: "도(C3) - 순간 잡음(B2,
    /// 3윈도우) - 도(C3)"에서 잡음을 앞의 도로 흡수하면 "도, 도" 두 개가 나란히 남는데, 원래
    /// 하나로 이어 부른 같은 음이므로 이것도 하나로 합쳐야 한다(실기기 로그로 실제 확인한 패턴).
    static func mergeAdjacentSamePitch(_ notes: [SegmentedNote]) -> [SegmentedNote] {
        guard notes.count > 1 else { return notes }

        var result: [SegmentedNote] = [notes[0]]
        for note in notes.dropFirst() {
            guard let last = result.last, last.midiNote == note.midiNote else {
                result.append(note)
                continue
            }
            let mergedEnd = note.onsetTime + note.duration
            result[result.count - 1] = SegmentedNote(
                midiNote: last.midiNote,
                onsetTime: last.onsetTime,
                duration: mergedEnd - last.onsetTime,
                averageConfidence: (last.averageConfidence + note.averageConfidence) / 2
            )
        }
        return result
    }
}
