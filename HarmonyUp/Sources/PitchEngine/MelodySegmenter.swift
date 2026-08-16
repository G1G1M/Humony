import Foundation

/// 녹음이 끝난 뒤 통째로 들어온 오디오 버퍼를, "부른 음 하나하나"(음높이+시작시간+길이)로 잘라낸다.
/// `MelodySession`은 실시간 프레임을 하나씩만 받는 구조라 이 배치(다 녹음된 걸 한 번에 분석) 방식엔
/// 안 맞는다 — 이 타입이 그 자리를 채우는 새 배치 전용 분석기다. 조성 판별(`KeyDetector`)과 화음 생성
/// (`ChordGenerator`)은 이미 순수 함수라 이 타입의 출력을 그대로 받아 재사용할 수 있다.
enum MelodySegmenter {

    struct SegmentedNote {
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
        // 이보다 짧게 지속된 구간은 숨소리/발음 전환 같은 잡음으로 보고 버린다(초 단위).
        var minimumNoteDuration: Double = 0.08
        var yinConfiguration: YINPitchDetector.Configuration = .default
        var vadConfiguration: VoiceActivityDetector.Configuration = .default

        static let `default` = Configuration()
    }

    static func segment(samples: [Float], sampleRate: Double, configuration: Configuration = .default) -> [SegmentedNote] {
        guard samples.count >= configuration.windowSize, sampleRate > 0 else { return [] }

        let windows = analyzeWindows(samples: samples, sampleRate: sampleRate, configuration: configuration)
        guard !windows.isEmpty else { return [] }

        // 디바운스 -> 런랭스 인코딩, 두 단계로 나누면("이 값이 확정됐는지"와 "확정된 값들을 구간으로
        // 묶기"를 분리) 한 번에 다 처리하는 것보다 각 단계를 따로 검증하기 쉽다.
        let debounced = debounce(windows.map(\.midiNote), streakRequired: configuration.streakRequired)

        return runLengthEncode(
            debounced,
            confidences: windows.map(\.confidence),
            hop: configuration.hop,
            windowSize: configuration.windowSize,
            sampleRate: sampleRate,
            minimumDuration: configuration.minimumNoteDuration
        )
    }

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

    // MARK: - 2단계: 디바운스

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

    // MARK: - 3단계: 런랭스 인코딩 -> SegmentedNote

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

        func flush(endIndexExclusive: Int) {
            guard let runNote, let runStart, endIndexExclusive > runStart else { return }
            let onset = Double(runStart) * Double(hop) / sampleRate
            let lastWindowStart = Double(endIndexExclusive - 1) * Double(hop) / sampleRate
            let end = lastWindowStart + Double(windowSize) / sampleRate
            let duration = end - onset
            guard duration >= minimumDuration else { return }

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

        return notes
    }
}
