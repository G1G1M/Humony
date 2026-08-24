import SwiftUI
import SwiftData

/// `PracticeView`의 "따라 부르기 채점" 책임 — 성부 선택, 먼저 들어보기, 소절 녹음, 배치 채점,
/// 결과 표시. 나머지 책임은 `PracticeView.swift`(상태/body), `PracticeView+Layout.swift`(레이아웃),
/// `PracticeView+Capture.swift`(녹음/분석)에 있다.
///
/// **136절, 채점 재설계**: 예전 채점은 "마지막 음 하나의 화음을 목표음으로 붙잡고 지속 발성"하는
/// 실시간 프레임 채점이었다 — 이 앱의 목표는 한 음을 배우는 게 아니라 **멜로디에서 뽑아낸 화음
/// 한 소절을 연습하는 것**이라 흐름째 바꿨다.
///
/// **듣기와 부르기를 시간상 분리한다**: 목표 성부를 재생하면서 동시에 채점하지 않는다. 그러면
/// 스피커로 낸 화음이 마이크로 되돌아와 "사용자가 부른 음"으로 잘못 채점되는데, 그걸 막으려면
/// 이어폰을 강제하거나 오디오 세션을 `.voiceChat`(하드웨어 에코 캔슬링)으로 바꿔야 한다 — 후자는
/// 132절까지 튜닝해온 녹음 품질(YIN 정확도, WORLD 분석)에 영향이 갈 수 있다. 먼저 듣고, 소리를
/// 끄고, 그다음 부르게 하면 그 위험을 아예 만들지 않는다(`startCaptureAfterPermissionGranted`의
/// 기존 피드백 가드도 그대로 유효하다).
extension PracticeView {

    /// 채점 카드 — 136절부터 여닫기 없이 항상 펼쳐져 있다("바로 불러서 채점할 수 있게" 요청).
    var scoringCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("따라 부르기 채점", systemImage: "target")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .padding(.top, Theme.Spacing.xs)

            voicePicker
            targetPreview

            HStack(spacing: Theme.Spacing.sm) {
                listenButton
                singButton
            }

            scoringStatusContent
        }
    }

    // MARK: - 조작부

    /// 어느 성부를 연습할지 — 멜로디는 원곡 그대로라 연습 대상이 아니고, 화음 3성부만 고른다.
    private var voicePicker: some View {
        Picker("연습할 성부", selection: $scoringVoice) {
            ForEach(ChordGenerator.Interval.allCases, id: \.self) { interval in
                Text(interval.koreanLabel).tag(interval)
            }
        }
        .pickerStyle(.segmented)
        // 녹음/채점 중에 목표가 바뀌면 방금 부른 소리를 엉뚱한 성부로 채점하게 된다.
        .disabled(scoringPhase == .recording || scoringPhase == .analyzing)
    }

    /// 이 성부에서 불러야 할 음을 순서대로 보여준다 — "무엇을 불러야 하는지"를 소리로만
    /// 알려주면 음이름을 눈으로 확인할 방법이 없다(악보에도 4성부가 다 나오지만, 지금 고른
    /// 성부만 따로 뽑아 보여주는 게 연습 중에는 더 직접적이다).
    @ViewBuilder
    private var targetPreview: some View {
        let targets = scoringTargetNoteNames
        if targets.isEmpty {
            Text("이 성부는 화음이 만들어지지 않았어요 — 다른 성부를 골라보세요")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.warning)
        } else {
            Text("불러야 할 음: " + targets.joined(separator: " · "))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.intervalColor(for: scoringVoice))
        }
    }

    private var listenButton: some View {
        let voice = VoiceHarmonyTrackBuilder.Voice.harmony(scoringVoice)
        let isPlaying = playingSoloVoice == voice
        return Button {
            toggleVoiceSolo(voice)
        } label: {
            Label(isPlaying ? "정지" : "먼저 들어보기", systemImage: isPlaying ? "stop.fill" : "ear")
                .frame(maxWidth: .infinity)
        }
        .harmonyButtonStyle()
        // 채점 녹음 중에 재생하면 그 소리가 그대로 마이크로 들어간다 — 이 흐름의 전제(듣기와
        // 부르기를 시간상 분리)를 UI에서도 지킨다.
        .disabled(scoringPhase == .recording || isPlayingVoiceHarmony || scoringTargetFrequencies.isEmpty)
    }

    @ViewBuilder
    private var singButton: some View {
        if scoringPhase == .recording {
            Button {
                stopScoringRecording()
            } label: {
                Label("그만 부르기", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .harmonyButtonStyle(prominent: true)
        } else {
            Button {
                startScoringRecording()
            } label: {
                Label(scoringPhase == .result ? "다시 부르기" : "따라 부르기", systemImage: "mic.fill")
                    .frame(maxWidth: .infinity)
            }
            .harmonyButtonStyle(prominent: true)
            .disabled(scoringPhase == .analyzing || playingSoloVoice != nil || isPlayingVoiceHarmony || scoringTargetFrequencies.isEmpty)
        }
    }

    // MARK: - 상태별 내용

    @ViewBuilder
    private var scoringStatusContent: some View {
        switch scoringPhase {
        case .idle:
            Text("먼저 들어본 다음, 소리를 끄고 그 성부를 처음부터 끝까지 불러보세요")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)

        case .recording:
            HStack(spacing: Theme.Spacing.sm) {
                Circle()
                    .fill(Theme.warning)
                    .frame(width: 8, height: 8)
                Text(String(format: "듣고 있어요 · %.1f초", Double(scoringBuffer.count) / scoringSampleRate))
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                Button("취소") { cancelScoringRecording() }
                    .font(Theme.Typography.caption)
            }

        case .analyzing:
            PulsingLoadingLabel(message: "채점하는 중이에요")

        case .result:
            if let result = scoringResult, let voice = scoringResultVoice {
                scoringResultContent(result: result, voice: voice)
            }

        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.warning)
        }
    }

    private func scoringResultContent(result: HarmonyPracticeScorer.Result, voice: ChordGenerator.Interval) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Text(String(format: "%.0f%%", result.onPitchRatio * 100))
                    .font(Theme.Typography.title3Bold)
                    .foregroundStyle(result.onPitchRatio >= 0.7 ? Theme.pitchGood : Theme.warning)
                Text("\(voice.koreanLabel) 정확도")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Text(String(format: "평균 ±%.0f cent", result.averageAbsCentsOffset))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            // 절대값 평균만으론 "얼마나" 벗어났는지만 알 수 있다 — 부호 있는 평균을 같이 봐서
            // "어느 쪽으로" 치우치는지 한 줄로 알려준다(연습에서 바로 고칠 수 있는 정보).
            if let biasMessage = Self.biasMessage(signedCents: result.averageSignedCentsOffset) {
                Text(biasMessage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            if result.missedCount > 0 || result.extraCount > 0 {
                Text(Self.missedExtraMessage(missed: result.missedCount, extra: result.extraCount))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ForEach(Array(result.steps.enumerated()), id: \.offset) { _, step in
                scoringStepRow(step)
            }
        }
    }

    private func scoringStepRow(_ step: HarmonyPracticeScorer.StepResult) -> some View {
        let targetName = Self.noteName(forMIDINote: step.targetMIDINote)
        return HStack(spacing: Theme.Spacing.xs) {
            Text(targetName)
                .frame(minWidth: 34, alignment: .leading)
            if let sung = step.sungMIDINote, let cents = step.centsOffset {
                Text("→ \(Self.noteName(forMIDINote: sung))")
                    .foregroundStyle(.secondary)
                Text(String(format: "%+.0f¢", cents))
                    .foregroundStyle(step.isOnPitch ? Theme.pitchGood : Theme.warning)
                Spacer()
                Image(systemName: step.isOnPitch ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(step.isOnPitch ? Theme.pitchGood : .secondary)
            } else {
                Text("→ 안 부름")
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    // MARK: - 표시용 문구 (순수 함수 — 뷰 상태와 무관해서 테스트하기 쉽다)

    /// 부호 있는 평균 편차로 "높게/낮게 부르는 편"을 알려준다. 허용 오차(35cent)의 절반쯤부터
    /// 말해주는데, 그보다 작으면 방향이라기보다 그냥 흔들림이라 조언이 되지 않는다.
    static func biasMessage(signedCents: Double) -> String? {
        let threshold = PitchScorer.onPitchToleranceCents / 2
        guard abs(signedCents) >= threshold else { return nil }
        return signedCents > 0 ? "전반적으로 살짝 높게 부르는 편이에요" : "전반적으로 살짝 낮게 부르는 편이에요"
    }

    static func missedExtraMessage(missed: Int, extra: Int) -> String {
        var parts: [String] = []
        if missed > 0 { parts.append("안 부른 음 \(missed)개") }
        if extra > 0 { parts.append("목표에 없는 음 \(extra)개") }
        return parts.joined(separator: " · ")
    }

    static func noteName(forMIDINote midiNote: Int) -> String {
        NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?"
    }

    // MARK: - 목표 시퀀스

    var scoringTargetFrequencies: [Double] {
        HarmonyPracticeScorer.targetFrequencies(from: melodySteps, interval: scoringVoice)
    }

    var scoringTargetNoteNames: [String] {
        melodySteps.compactMap { $0.harmonyVoices?[scoringVoice] }
    }

    // MARK: - 녹음/채점 흐름

    /// "따라 부르기" — 재생을 모두 끊고 마이크만 연다. 멜로디 캡처(`startQuickRecording`)와 같은
    /// `audioCapture`를 공유하고, 콜백이 `scoringPhase`를 보고 이쪽 분기를 탄다.
    func startScoringRecording() {
        guard !scoringTargetFrequencies.isEmpty else { return }

        // 듣기와 부르기는 절대 겹치지 않는다 — 재생 중이었다면 여기서 확실히 끊는다.
        soloVoicePlayer.stop()
        playingSoloVoice = nil
        voiceHarmonyPlayer.stop()
        isPlayingVoiceHarmony = false
        startingNotePlayer.stop()
        isPlayingStartingNote = false

        scoringBuffer = []
        scoringResult = nil
        scoringResultVoice = nil
        scoringPhase = .recording
        beginCapturingIfNeeded()
    }

    /// "그만 부르기"(또는 60초 상한 도달) — 마이크를 멈추고 모은 녹음을 한 번에 채점한다.
    func stopScoringRecording() {
        guard scoringPhase == .recording else { return }
        audioCapture.stop()
        isCapturing = false
        scoringPhase = .analyzing
        recordingLevel = 0

        let voice = scoringVoice
        let targets = scoringTargetFrequencies
        let samples = scoringBuffer
        let rate = scoringSampleRate

        // 빠른 녹음(activeAnalysisToken)과 같은 이유의 세대 토큰 — 타임아웃으로 이미 에러 처리한
        // 뒤에도 백그라운드 세그멘테이션은 계속 돌 수 있고, 그 결과가 뒤늦게 도착해 사용자가
        // 이미 시작한 다음 시도를 덮어쓰면 안 된다.
        let token = UUID()
        activeScoringToken = token
        Task {
            let scored = await Self.scoreWithTimeout(
                samples: samples,
                sampleRate: rate,
                targets: targets,
                timeout: analysisTimeout
            )
            guard activeScoringToken == token else { return }
            guard let scored else {
                scoringPhase = .error("채점이 너무 오래 걸리고 있어요 — 다시 시도해주세요")
                return
            }
            scoringResult = scored
            scoringResultVoice = voice
            scoringPhase = .result
            saveAttempt(result: scored, interval: voice)
            // 실시간 프레임 햅틱(3프레임 유지) 대신, 채점이 끝난 순간 결과에 맞춰 한 번 울린다.
            scoringSuccessHaptic.notificationOccurred(scored.onPitchRatio >= 0.7 ? .success : .warning)
        }
    }

    // MARK: - 기록 저장

    /// 채점 결과를 기록으로 남긴다 — 같은 녹음에서 성부를 바꿔 여러 번 채점하면 **하나의
    /// 세션 아래**에 시도가 쌓인다(`currentSession`을 재사용). 그래야 기록 탭에서
    /// "이 녹음에서 3도 82%, 5도 71%"처럼 한 세션으로 묶여 보인다.
    func saveAttempt(result: HarmonyPracticeScorer.Result, interval: ChordGenerator.Interval) {
        let session = currentSession ?? makeSession()
        guard let session else { return }

        let attempt = PracticeAttempt(result: result, interval: interval, date: Date())
        attempt.session = session
        modelContext.insert(attempt)

        // SwiftUI의 autosave는 저장 시점이 시스템 타이밍(백그라운드 전환 등)에 맡겨져 있다 —
        // insert 직후 세션을 리셋하거나 앱이 예기치 않게 종료되면 그 사이 저장이 안 될 수 있다.
        // 채점 시도 하나하나가 사용자에게 의미있는 기록이라 명시적으로 즉시 저장한다.
        try? modelContext.save()
    }

    /// 이번 녹음에 대응하는 세션을 처음 만든다 — 그때 부른 멜로디와 화음까지 스냅샷으로 담아서,
    /// 기록에서 그때의 악보를 다시 볼 수 있게 한다(오디오는 저장하지 않는다).
    private func makeSession() -> PracticeSession? {
        guard !melodySteps.isEmpty, let key = melodySession.detectedKey else { return nil }
        let session = PracticeSession.snapshot(of: melodySteps, keyName: key.name, date: Date())
        modelContext.insert(session)
        currentSession = session
        return session
    }

    /// 녹음 도중 "취소" — 분석을 돌리지 않고 지금까지 모은 소리를 버린다(빠른 녹음의
    /// `cancelQuickRecording`과 같은 역할). 세션 리셋에서도 이걸 쓴다.
    func cancelScoringRecording() {
        guard scoringPhase == .recording else { return }
        audioCapture.stop()
        isCapturing = false
        scoringBuffer = []
        scoringPhase = .idle
        recordingLevel = 0
    }

    /// `MelodySegmenter`는 동기·취소 불가라 타임아웃과 경합시킨다 — 빠른 녹음의
    /// `analyzeWithTimeout`과 같은 패턴이고, 이유도 같다(60초 녹음이면 YIN을 윈도우마다 도는
    /// 비용이 커서 붙잡고 기다리는 대신 통제권을 사용자에게 돌려준다).
    private static func scoreWithTimeout(
        samples: [Float],
        sampleRate: Double,
        targets: [Double],
        timeout: TimeInterval
    ) async -> HarmonyPracticeScorer.Result? {
        await withTaskGroup(of: HarmonyPracticeScorer.Result?.self) { group in
            group.addTask {
                HarmonyPracticeScorer.score(recordingSamples: samples, sampleRate: sampleRate, targetFrequencies: targets)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
}
