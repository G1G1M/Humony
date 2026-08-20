import SwiftUI
import SwiftData
import AVFAudio

/// `PracticeView`의 마이크 캡처/녹음/분석 책임 — 권한 확인, 빠른 녹음 시작/중지, 배치 분석
/// (타임아웃 안전망 포함), 분석 결과 반영, 세션 리셋까지. 나머지 책임은 `PracticeView.swift`
/// (상태/body), `PracticeView+Layout.swift`(레이아웃)에 있다.
extension PracticeView {
    /// 측정(마이크 캡처)이 꺼져 있으면 켠다. 이미 켜져 있으면 아무 것도 하지 않는다(중복 start 방지).
    /// "녹음 시작"과 "채점하기" 둘 다 이걸 호출해서, 같은 audioCapture 하나를 상황에 맞게 공유한다 —
    /// 실제로 무엇을 할지는 audioCapture의 콜백(startCaptureAfterPermissionGranted)이 그때그때의
    /// quickRecordPhase/activeScoringInterval을 보고 판단한다.
    ///
    /// 마이크 권한을 먼저 확인한다 — 거부된 상태에서 그냥 start()를 호출하면 실패 이유가 눈에 잘
    /// 안 띄었다. 여기서 미리 걸러서 전용 UI(micPermissionDeniedContent)로 보여준다.
    func beginCapturingIfNeeded() {
        #if DEBUG
        print("[PracticeView] beginCapturingIfNeeded() 호출 — isCapturing=\(isCapturing)\(isCapturing ? " (이미 켜져있다고 판단해 건너뜀)" : "")")
        #endif
        guard !isCapturing else { return }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            micPermissionDenied = false
            startCaptureAfterPermissionGranted()
        case .denied:
            micPermissionDenied = true
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    if granted {
                        beginCapturingIfNeeded()
                    } else {
                        micPermissionDenied = true
                    }
                }
            }
        @unknown default:
            micPermissionDenied = true
        }
    }

    func startCaptureAfterPermissionGranted() {
        do {
            try audioCapture.start { result, rawSamples, rawSampleRate in
                // 녹음 재생 중엔 마이크를 무시한다 — 스피커로 낸 소리가 다시 마이크로
                // 들어가는 피드백 루프를 막기 위한 기존 원칙(화음 재생 때부터 이어옴).
                guard !isPlayingRecording else { return }

                // 녹음 중엔 이 프레임을 quickRecordBuffer에 쌓기만 한다. 녹음이 끝난 뒤 "따라 부르기
                // 채점"으로 마이크가 다시 켜질 때는 quickRecordPhase가 더 이상 .recording이 아니므로
                // 이 분기를 건너뛰고 곧장 아래 채점 로직으로 간다.
                if quickRecordPhase == .recording {
                    quickRecordBuffer.append(contentsOf: rawSamples)
                    quickRecordSampleRate = rawSampleRate
                    // 헤일로 애니메이션용 실시간 음량 — VoiceActivityDetector와 같은 방식(제곱
                    // 평균제곱근)으로 이번 프레임만의 순간 음량을 계산한다(누적 버퍼 전체가 아니라
                    // rawSamples만 봐야 "지금 이 순간"이 반영된다).
                    if !rawSamples.isEmpty {
                        let meanSquare = rawSamples.reduce(Float(0)) { $0 + $1 * $1 } / Float(rawSamples.count)
                        recordingLevel = min(1, sqrt(meanSquare) / recordingLevelNormalization)
                    }
                    if Double(quickRecordBuffer.count) / rawSampleRate >= quickRecordMaxDuration {
                        stopQuickRecording()
                    }
                    return
                }

                // 이 시점부터는 "따라 부르기 채점" 중에만 마이크가 켜져 있다 — 채점 대상이 없으면 할 게 없다.
                guard let result, let interval = activeScoringInterval, let target = lockedScoringTargets[interval] else { return }

                // 원본 프레임 주파수를 그대로 채점하면 비브라토/발성 흔들림 때문에 바늘이
                // 지저분하게 튄다 — 스무딩을 거친 값으로 채점해서 "지금 대충 맞는지"가 잘 보이게 한다.
                let smoothedFrequency = pitchSmoother.smooth(frequency: result.frequency)
                let score = PitchScorer.score(sungFrequency: smoothedFrequency, targetFrequency: target.frequency)
                latestScores[interval] = score
                if let score {
                    // 이번 시도가 끝나면 PracticeSummary로 압축해서 저장한다.
                    scoreSampleBuffers[interval, default: []].append(score)
                    updateOnPitchStreak(interval: interval, isOnPitch: score.isOnPitch)
                } else {
                    updateOnPitchStreak(interval: interval, isOnPitch: false)
                }
            }
            isCapturing = true
        } catch {
            statusText = "마이크 시작 실패: \(error.localizedDescription)"
        }
    }

    /// "녹음 시작" 버튼 — 사용자가 "녹음 그만"을 누를 때까지 quickRecordBuffer에 원본을 그대로 모으기만
    /// 한다. 마이크 자체는 beginCapturingIfNeeded()가 켜는 같은 audioCapture를 그대로 재사용한다 —
    /// 그 안의 클로저가 quickRecordPhase를 보고 알아서 녹음용 분기를 탄다.
    func startQuickRecording() {
        #if DEBUG
        print("[PracticeView] startQuickRecording() 호출 — hasCapturedNote=\(hasCapturedNote), isCapturing=\(isCapturing)")
        #endif
        // 참고음을 듣던 중이었다면 여기서 멈춘다 — 녹음이 시작되면 그 소리가 마이크로 되먹임될 수 있다.
        startingNotePlayer.stop()
        isPlayingStartingNote = false
        quickRecordBuffer = []
        quickRecordPhase = .recording
        beginCapturingIfNeeded()
    }

    /// "녹음 그만" 버튼(또는 60초 상한 도달 시 자동 호출) — 마이크를 멈추고, 지금까지 모은 녹음
    /// 전체를 RecordingAnalyzer로 한 번에 분석한다. YIN을 윈도우마다 돌리는 무거운 계산이라
    /// Task로 감싸서 메인 스레드가 멈추지 않게 한다.
    func stopQuickRecording() {
        #if DEBUG
        print("[PracticeView] stopQuickRecording() 호출 — quickRecordPhase=\(quickRecordPhase), 모인 샘플=\(quickRecordBuffer.count)개")
        #endif
        guard quickRecordPhase == .recording else {
            #if DEBUG
            print("[PracticeView] stopQuickRecording() — quickRecordPhase가 .recording이 아니라서 무시됨(가드에 걸림)")
            #endif
            return
        }
        audioCapture.stop()
        isCapturing = false
        quickRecordPhase = .analyzing(.voiceAnalysis)
        recordingLevel = 0

        // 마이크 원본 신호의 크기가 기기마다 크게 다를 수 있다 — `.measurement` 모드는 AGC를
        // 꺼서 원본 게인이 그대로 드러나는데, 아이패드 실기기에서 가까이 대고 불러도 최대
        // 진폭이 0.01 안팎으로 확인됨(63절 진단 결과, 추측 아닌 실측). 이 정도 크기는
        // `VoiceActivityDetector`의 에너지 임계값(0.0001, 평균 제곱)을 거의 못 넘어서 "노래가
        // 인식되지 않았어요"로 이어졌다. "내 목소리로 화음" 재생 직전에 쓰던 것과 같은
        // `AudioGain.normalizeLoudness`를 분석 직전에도 적용해서, 이후 파이프라인(VAD/YIN)이
        // 기기별 원본 게인 차이에 휘둘리지 않게 한다.
        let rawPeak = quickRecordBuffer.map { abs($0) }.max() ?? 0
        let samples = AudioGain.normalizeLoudness(quickRecordBuffer)
        let rate = quickRecordSampleRate
        #if DEBUG
        // 입력 자체(정규화 전 원본 최대 진폭 + 녹음 길이)를 먼저 찍어서, 이후 MelodySegmenter의
        // 단계별 로그(원본 -> 중앙값 필터 -> 디바운스 -> 최종 음표)와 대조해 "부른 음보다 악보에
        // 음표가 더 많이 나온다" 같은 문제를 어느 단계에서 조사할지 좁힐 수 있게 한다.
        print("[PracticeView] 녹음 종료 — 길이 \(String(format: "%.2fs", Double(quickRecordBuffer.count) / rate)), 원본 최대 진폭 \(String(format: "%.5f", rawPeak))")
        #endif
        // 명세서(v1.0) "안전망 장치" — 60초 분량 녹음은 YIN을 윈도우마다 도는 RecordingAnalyzer가
        // 평소보다 오래 걸릴 수 있어서, 12초를 넘기면 붙잡고 기다리는 대신 에러로 즉시 알리고
        // (기존 errorContent의 "다시 녹음" 버튼이 곧 재시도 버튼) 사용자에게 통제권을 돌려준다.
        // 토큰으로 "이 시도가 아직 최신인지"를 확인하는 이유: 타임아웃으로 이미 에러 처리한 뒤에도
        // 백그라운드 analyze() 자체는 계속 돌고 있을 수 있는데(진짜로 취소되는 게 아니라 결과를
        // 무시하는 것뿐), 그게 뒤늦게 끝나 사용자가 이미 새로 시작한 다음 시도의 결과를 덮어쓰면 안 된다.
        let token = UUID()
        activeAnalysisToken = token
        Task {
            let analyzed = await Self.analyzeWithTimeout(samples: samples, sampleRate: rate, timeout: analysisTimeout)
            guard activeAnalysisToken == token else { return }
            guard let analyzed else {
                quickRecordPhase = .error("분석이 너무 오래 걸리고 있어요 — 다시 시도해주세요")
                return
            }
            quickRecordPhase = .analyzing(.harmonyGeneration)
            // "진행률 바가 반만 채워진 채로 있다가 그냥 다음으로 넘어간다" 실기기 피드백 —
            // 화음 생성(harmonizeSequence 등) 자체는 거의 즉시 끝나서, 이 줄 바로 다음에
            // applyQuickRecordResult가 quickRecordPhase를 곧장 .result로 바꿔버리면 SwiftUI가
            // .harmonyGeneration(진행률 100%) 상태를 한 프레임도 그리지 못하고 넘어갈 수 있다 —
            // 사용자 눈엔 "50%에서 바로 사라짐"으로 보인다. 진행률 바가 100%까지 차오르는 걸
            // (ShimmerProgressBar의 0.3초 채움 애니메이션 포함) 실제로 볼 수 있을 만큼만 최소
            // 대기한다.
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard activeAnalysisToken == token else { return } // 대기하는 사이 새 시도가 시작됐으면 여기서도 무시
            applyQuickRecordResult(analyzed)
        }
    }

    /// `RecordingAnalyzer.analyze`(동기, 취소 불가)를 타임아웃과 경합시킨다 — 분석이 제때 안
    /// 끝나면 nil을 돌려주고, 실제 analyze() 자신은 백그라운드에서 계속 돌다 나중에 조용히
    /// 버려진다(위 activeAnalysisToken 가드가 그 결과를 무시하게 한다).
    private static func analyzeWithTimeout(
        samples: [Float],
        sampleRate: Double,
        timeout: TimeInterval
    ) async -> RecordingAnalyzer.AnalyzedRecording? {
        await withTaskGroup(of: RecordingAnalyzer.AnalyzedRecording?.self) { group in
            group.addTask {
                RecordingAnalyzer.analyze(recordingSamples: samples, sampleRate: sampleRate)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }

    /// "취소"(X) 버튼 — 참고 디자인의 Discard와 같은 역할. "녹음 그만"과 달리 분석을 아예
    /// 돌리지 않고 지금까지 모은 소리를 그냥 버린 뒤 대기 상태로 되돌아간다.
    func cancelQuickRecording() {
        guard quickRecordPhase == .recording else { return }
        audioCapture.stop()
        isCapturing = false
        quickRecordBuffer = []
        quickRecordPhase = .idle
        recordingLevel = 0
    }

    /// RecordingAnalyzer의 배치 분석 결과를, 기존 UI가 그대로 소비할 수 있는 상태로 반영한다.
    func applyQuickRecordResult(_ analyzed: RecordingAnalyzer.AnalyzedRecording) {
        #if DEBUG
        print("[PracticeView] applyQuickRecordResult() 시작 — analyzed.notes=\(analyzed.notes.count)개, 이전 hasCapturedNote=\(hasCapturedNote)")
        #endif
        guard !analyzed.notes.isEmpty else {
            // "가까이서 불러도 인식이 안 된다"는 걸 추측이 아니라 실측으로 진단하기 위해, 실제
            // 녹음된 파형의 최대 진폭을 에러 메시지에 같이 보여준다. VoiceActivityDetector의
            // 에너지 임계값(0.0001, 평균 제곱)과 비교했을 때 이 값이 0에 가까우면 마이크가 소리를
            // 아예 못 잡은 것(세션/권한/게인 문제)이고, 정상 발화 수준(대략 0.05 이상)인데도 음이
            // 하나도 안 잡히면 VAD가 아니라 다른 단계(YIN 신뢰도, 디바운스 등)가 원인이라는 뜻이다.
            let peakAmplitude = analyzed.voiceSamples.map { abs($0) }.max() ?? 0
            #if DEBUG
            // 원시 진폭값은 디버그 로그로만 남긴다 — 예전엔 이 숫자를 사용자에게 그대로
            // 보여줬는데(%.5f), 이론 지식 없는 사용자한텐 그냥 의미 없는 소수점 숫자라
            // 크리틱에서 지적받음(P1). 진단은 여기 로그로, 사용자 메시지는 평이한 언어로 분리.
            print("[PracticeView] 인식 실패 — 측정된 최대 음량: \(String(format: "%.5f", peakAmplitude))")
            #endif
            // 0.01은 "마이크가 소리를 거의 못 잡은 수준"과 "소리는 잡혔지만 다른 이유로
            // 인식이 안 된 수준"을 가르는 대략적인 경계 — VoiceActivityDetector 임계값(0.0001)
            // 보다는 한참 위, "정상 발화 수준"(대략 0.05, 위 주석 참고)보다는 아래로 잡았다.
            let message = peakAmplitude < 0.01
                ? "소리가 거의 안 들렸어요 — 마이크에 더 가까이 대고 불러주세요"
                : "노래가 인식되지 않았어요 — 음정을 살려서 더 또렷하게 다시 불러주세요"
            quickRecordPhase = .error(message)
            return
        }

        melodySession.reset()

        // 1단계: 세그멘테이션된 음을 순서대로 melodySession에 그대로 먹인다 — 합성 DetectionResult를
        // 만들어 실시간 캡처와 같은 record() 경로로 흘려보내는 패턴이다. 이렇게 하면 melodySession의
        // detectedKey/lastNote/suggestedHarmony가 실시간 캡처 경로와 완전히 같은 방식으로 채워져서, 이후
        // "내 목소리로 화음"/채점 로직(pitchRatio, toggleScoring 등)을 전혀 손대지 않고 그대로 재사용할 수 있다.
        for note in analyzed.notes {
            let frequency = NoteNameConverter.frequency(forMIDINote: note.midiNote)
            guard let converted = NoteNameConverter.convert(frequency: frequency) else { continue }
            melodySession.record(AudioCapture.DetectionResult(
                frequency: frequency,
                noteName: converted.noteName,
                centsOffset: 0,
                confidence: note.averageConfidence,
                pitchClass: converted.pitchClass,
                frameDuration: note.duration,
                samples: [],
                sampleRate: analyzed.sampleRate
            ))
        }

        guard melodySession.detectedKey != nil else {
            quickRecordPhase = .error("조성을 판별하지 못했어요 — 조금 더 길게 불러서 다시 녹음해주세요")
            return
        }
        // 화음 API 제거(2026-08-20) 이후로는 스텝마다 화음을 계산하지 않는다 — 멜로디
        // 음이름/시작시각/길이만 채운다(harmony/harmonyVoices는 nil로 남음). ChordGenerator
        // 자체는 지우지 않았으니, 나중에 다시 필요하면 여기서 harmonizeSequence를 다시
        // 호출하기만 하면 된다(docs/CONCEPTS.md 참고).
        melodySteps = analyzed.notes.map { note in
            let frequency = NoteNameConverter.frequency(forMIDINote: note.midiNote)
            let noteName = NoteNameConverter.convert(frequency: frequency)?.noteName ?? "?"
            return MelodyStep(
                noteName: noteName,
                midiNote: note.midiNote,
                onsetTime: note.onsetTime,
                duration: note.duration
            )
        }
        // "다시 녹음"으로 새 악보 내용이 들어올 때도 다시 "만드는 중" 표시부터 보여준다 —
        // VexFlowScoreView.Coordinator가 새 페이로드의 renderScore 호출이 끝나면 false로 되돌림.
        isScoreRendering = true
        scoreContentVersion += 1

        // 녹음 원본은 재생/채점을 다시 붙일 때를 위해 계속 들고 있는다.
        recentVoiceBuffer = analyzed.voiceSamples
        recentVoiceSampleRate = analyzed.sampleRate

        hasCapturedNote = true
        quickRecordPhase = .result(noteCount: analyzed.notes.count)
        #if DEBUG
        print("[PracticeView] applyQuickRecordResult 완료 — hasCapturedNote=\(hasCapturedNote), melodySteps=\(melodySteps.count)개, suggestedHarmony=\(melodySession.suggestedHarmony != nil ? "있음" : "nil")")
        #endif
    }

    func resetSession() {
        if let active = activeScoringInterval {
            finalizeCurrentAttempt(interval: active) // 리셋 직전까지의 채점 시도도 버리지 않고 기록으로 남긴다
        }

        recentVoiceBuffer = []
        isScoringExpanded = false
        lastSavedInterval = nil
        activeScoringInterval = nil
        lockedScoringTargets = [:]
        latestScores = [:]
        scoreSampleBuffers = [:]
        onPitchStreak = [:]
        onPitchHapticFired = [:]
        pitchSmoother.reset()
        melodySession.reset()
        hasCapturedNote = false
        melodySteps = []
        statusText = ""
        quickRecordPhase = .idle
        quickRecordBuffer = []
        recordingLevel = 0
    }

    /// 방금 녹음한 원본을 그대로 들어본다 — 화음 없이, 화음 API 제거(116절) 이후 멜로디
    /// 인식 정확도를 귀로도 확인할 수 있게 다시 추가한 재생 버튼의 동작.
    func togglePlayback() {
        if isPlayingRecording {
            recordingPlayer.stop()
            isPlayingRecording = false
            return
        }
        guard !recentVoiceBuffer.isEmpty else { return }
        do {
            isPlayingRecording = true
            try recordingPlayer.play(samples: recentVoiceBuffer, sampleRate: recentVoiceSampleRate) {
                isPlayingRecording = false
            }
        } catch {
            isPlayingRecording = false
            statusText = "재생 실패: \(error.localizedDescription)"
        }
    }
}
