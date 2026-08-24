import SwiftUI
import SwiftData
import AVFAudio

/// `PracticeView`의 마이크 캡처/녹음/분석 책임 — 권한 확인, 빠른 녹음 시작/중지, 배치 분석
/// (타임아웃 안전망 포함), 분석 결과 반영, 세션 리셋까지. 나머지 책임은 `PracticeView.swift`
/// (상태/body), `PracticeView+Layout.swift`(레이아웃)에 있다.
extension PracticeView {
    /// 측정(마이크 캡처)이 꺼져 있으면 켠다. 이미 켜져 있으면 아무 것도 하지 않는다(중복 start 방지).
    /// "녹음 시작"(멜로디 캡처)과 "따라 부르기"(채점) 둘 다 이걸 호출해서, 같은 audioCapture 하나를
    /// 상황에 맞게 공유한다 — 실제로 무엇을 할지는 audioCapture의 콜백
    /// (startCaptureAfterPermissionGranted)이 그때그때의 quickRecordPhase/scoringPhase를 보고 판단한다.
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
            // 이 콜백은 이제 피치 검출 결과(첫 파라미터)를 쓰지 않는다 — 멜로디 캡처든 채점이든
            // 둘 다 "원본 샘플을 모아뒀다가 멈춘 뒤 한 번에 배치 분석"하는 방식이라, 프레임별
            // 검출값이 필요한 소비자가 없어졌다(136절에 실시간 프레임 채점을 걷어낸 결과).
            try audioCapture.start { _, rawSamples, rawSampleRate in
                // 녹음/화음 재생 중엔 마이크를 무시한다 — 스피커로 낸 소리가 다시 마이크로
                // 들어가는 피드백 루프를 막기 위한 기존 원칙(화음 재생 때부터 이어옴).
                guard !isPlayingVoiceHarmony, playingSoloVoice == nil else { return }

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

                // 이 시점부터는 "따라 부르기 채점" 녹음 중에만 마이크가 켜져 있다. 멜로디 캡처와
                // 똑같이 원본을 모으기만 하고, 멈춘 뒤 stopScoringRecording()이 한 번에 분석한다 —
                // 프레임마다 채점하지 않는 이유는 목표가 "한 음 유지"가 아니라 "한 소절 부르기"라서,
                // 음정이 맞았는지는 부른 음을 다 잘라낸 뒤에야 목표 시퀀스와 맞춰볼 수 있기 때문이다.
                guard scoringPhase == .recording else { return }
                scoringBuffer.append(contentsOf: rawSamples)
                scoringSampleRate = rawSampleRate
                if !rawSamples.isEmpty {
                    let meanSquare = rawSamples.reduce(Float(0)) { $0 + $1 * $1 } / Float(rawSamples.count)
                    recordingLevel = min(1, sqrt(meanSquare) / recordingLevelNormalization)
                }
                if Double(scoringBuffer.count) / rawSampleRate >= quickRecordMaxDuration {
                    stopScoringRecording()
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
        // 120절, 화음 재설계: RecordingAnalyzer.analyze가 이미 ChordGenerator로 스텝별 화음을
        // 계산해뒀다(analyzed.harmonies) — 그 결과를 그대로 melodySteps에 실어서
        // SynthesizedHarmonyTrackBuilder가 재생 시 바로 쓸 수 있게 한다.
        melodySteps = RecordingAnalyzer.melodySteps(from: analyzed)
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
        // 123절 — "일반 노래로 부르면 화음이 애매하게 들린다" 진단용. 조성+스텝별 화음을 실측
        // 로그로 남겨서, 조성 판별이 틀렸는지/화음 계산 자체는 맞는데 다른 이유로 애매하게
        // 들리는지 구분한다(117~119절과 같은 방식 — UI로 상태를 짐작하지 말고 로그로 확인).
        if let key = melodySession.detectedKey {
            print("[PracticeView] 감지된 조성: \(key.name)")
        }
        let stepLog = melodySteps.map { step -> String in
            guard let voices = step.harmonyVoices else { return "\(step.noteName)(화음없음-온음계밖)" }
            let bass = voices[.bass] ?? "?"
            let third = voices[.third] ?? "?"
            let fifth = voices[.fifth] ?? "?"
            return "\(step.noteName)[베이스\(bass)/3도\(third)/5도\(fifth)]"
        }.joined(separator: ", ")
        print("[PracticeView] 스텝별 화음(\(melodySteps.count)개): \(stepLog)")
        #endif
    }

    func resetSession() {
        // 채점 녹음 중이었다면 그 소리는 버린다 — 예전엔 리셋 직전까지 쌓인 프레임 점수를 기록으로
        // 남겼지만, 지금 채점은 "소절을 끝까지 부른 뒤 한 번에 채점"하는 단위라 중간에 끊긴 녹음은
        // 애초에 채점 대상이 아니다(반쯤 부른 걸 점수로 남기면 기록이 오히려 왜곡된다).
        cancelScoringRecording()

        voiceHarmonyPlayer.stop()
        isPlayingVoiceHarmony = false
        mutedVoices = []
        soloVoicePlayer.stop()
        playingSoloVoice = nil
        recentVoiceBuffer = []
        scoringPhase = .idle
        scoringBuffer = []
        scoringResult = nil
        scoringResultVoice = nil
        activeScoringToken = nil
        melodySession.reset()
        hasCapturedNote = false
        melodySteps = []
        statusText = ""
        quickRecordPhase = .idle
        quickRecordBuffer = []
        recordingLevel = 0
    }

    /// 123절, 화음 재설계 2단계 — 멜로디+베이스+3도+5도를 전부 **사용자 자신의 목소리**로
    /// 만든다(`VoiceHarmonyTrackBuilder`, WORLD 피치시프트). 재생 조작부의 유일한 재생
    /// 수단이다 — 합성음 전용 "화음 듣기"(120절)는 135절에서, 원본 그대로 듣기는 135절에서
    /// 각각 뺐다(전자는 "내 목소리"로도 화음을 들을 수 있어 중복, 후자는 "원본/내 목소리
    /// 두 섹션을 하나로 합쳐달라"는 요청).
    func toggleVoiceHarmonyPlayback() {
        if isPlayingVoiceHarmony {
            voiceHarmonyPlayer.stop()
            isPlayingVoiceHarmony = false
            return
        }
        startVoiceHarmonyPlayback()
    }

    /// 128절 — "재생 중에도 성부를 껐다 켤 수 있게" 요청에 대한 1차 구현(사용자가 두 방식 중
    /// "즉시 재시작"을 선택). 4성부를 계속 각자 다른 재생 노드에 올려두는 진짜 실시간 믹싱은
    /// 109절에서 "노드마다 시작 시점이 미세하게 어긋나 화음이 밀린다"는 이유로 일부러
    /// 피했던 구조라 다시 위험을 감수하지 않는다 — 대신 뮤트 상태를 바꾼 즉시 지금 재생을
    /// 멈추고 새 뮤트 조합으로 처음부터 다시 시작한다(끊김은 있지만 거의 즉각적).
    func toggleMute(_ voice: VoiceHarmonyTrackBuilder.Voice) {
        if mutedVoices.contains(voice) {
            mutedVoices.remove(voice)
        } else {
            mutedVoices.insert(voice)
        }
        guard isPlayingVoiceHarmony else { return }
        voiceHarmonyPlayer.stop()
        startVoiceHarmonyPlayback()
    }

    /// `toggleVoiceHarmonyPlayback`(버튼으로 처음 시작)과 `toggleMute`(재생 중 뮤트 전환으로
    /// 재시작) 둘 다 여기로 모인다 — `mutedVoices`에 없는 성부만 골라 섞는다.
    ///
    /// **세대 토큰이 필요한 이유**: `voiceHarmonyPlayer.stop()`을 부른 직후 곧바로 새
    /// `play()`를 스케줄하면, 방금 멈춘 이전 재생의 완료 콜백이 뒤늦게(비동기로) 도착해
    /// `isPlayingVoiceHarmony = false`로 되돌려서 방금 시작한 새 재생의 상태를 덮어쓸 수
    /// 있다 — 매 시작마다 새 토큰을 발급하고, 완료 콜백이 자기 토큰과 지금 토큰이 같을
    /// 때만 상태를 되돌리게 해서 이 경쟁 상태를 막는다.
    private func startVoiceHarmonyPlayback() {
        guard !recentVoiceBuffer.isEmpty, !melodySteps.isEmpty else { return }

        let allVoices: [VoiceHarmonyTrackBuilder.Voice] = [.melody, .harmony(.bass), .harmony(.third), .harmony(.fifth)]
        let activeVoices = allVoices.filter { !mutedVoices.contains($0) }
        guard !activeVoices.isEmpty else {
            isPlayingVoiceHarmony = false
            statusText = "전부 음소거 상태예요 — 하나 이상 켜주세요"
            return
        }

        let bufferLength = recentVoiceBuffer.count
        let rate = recentVoiceSampleRate
        // 128절 — 합성음 버전과 같은 이유로 화음 3성부를 backingGain만큼 낮춰 리드 멜로디가
        // 앞으로 나오게 한다(멜로디 자체가 음소거됐으면 이 배율은 아무 트랙에도 안 걸림).
        let backingGain: Float = 0.65
        let tracks: [[Float]] = activeVoices.map { voice in
            let track = VoiceHarmonyTrackBuilder.build(melodySteps: melodySteps, sourceBuffer: recentVoiceBuffer, bufferLength: bufferLength, voice: voice, rate: rate)
            return voice == .melody ? track : track.map { $0 * backingGain }
        }
        // 합성음(122절)과 같은 이유로 화음 재생 전용 낮춘 목표 음량을 그대로 적용.
        let mixed = AudioGain.applyFadeInOut(
            AudioGain.normalizeLoudness(AudioGain.mix(tracks: tracks), targetRMS: 0.15, peakCeiling: 0.7),
            fadeSampleCount: Int(rate * 0.01)
        )

        let generation = UUID()
        voiceHarmonyPlaybackGeneration = generation
        do {
            isPlayingVoiceHarmony = true
            try voiceHarmonyPlayer.play(samples: mixed, sampleRate: rate) {
                if voiceHarmonyPlaybackGeneration == generation { isPlayingVoiceHarmony = false }
            }
        } catch {
            isPlayingVoiceHarmony = false
            statusText = "목소리 화음 재생 실패: \(error.localizedDescription)"
        }
    }

    /// 128절 — 멜로디/베이스/3도/5도를 각각 따로 들어본다(WORLD 버전). 포먼트/음량 조정이
    /// 실제로 어느 성부에 어떻게 들리는지 하나씩 떼어서 비교하기 위한 디버깅/비교용 버튼.
    func toggleVoiceSolo(_ voice: VoiceHarmonyTrackBuilder.Voice) {
        if playingSoloVoice == voice {
            soloVoicePlayer.stop()
            playingSoloVoice = nil
            return
        }
        guard !recentVoiceBuffer.isEmpty, !melodySteps.isEmpty else { return }

        let bufferLength = recentVoiceBuffer.count
        let rate = recentVoiceSampleRate
        let track = VoiceHarmonyTrackBuilder.build(melodySteps: melodySteps, sourceBuffer: recentVoiceBuffer, bufferLength: bufferLength, voice: voice, rate: rate)
        let processed = AudioGain.applyFadeInOut(
            AudioGain.normalizeLoudness(track, targetRMS: 0.15, peakCeiling: 0.7),
            fadeSampleCount: Int(rate * 0.01)
        )

        do {
            soloVoicePlayer.stop() // 다른 성부를 재생 중이었다면 먼저 끊고 새로 시작
            playingSoloVoice = voice
            try soloVoicePlayer.play(samples: processed, sampleRate: rate) {
                if playingSoloVoice == voice { playingSoloVoice = nil }
            }
        } catch {
            playingSoloVoice = nil
            statusText = "성부 재생 실패: \(error.localizedDescription)"
        }
    }
}
