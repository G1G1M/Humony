import SwiftUI

struct ContentView: View {
    @State private var statusText = "마이크 대기 중..."
    @State private var keyText = ""
    @State private var harmonyText = ""
    @State private var isPlayingTone = false
    @State private var tonePlaybackTask: Task<Void, Never>?
    @State private var isPlayingStartingNote = false
    @State private var startingNoteTask: Task<Void, Never>?
    @State private var scoringTarget: ChordGenerator.HarmonyNote?
    @State private var scoringTargetNoteName = ""
    @State private var currentScore: PitchScorer.Score?

    // 지금은(향후 곡 전체를 듣고 여러 화음을 뽑는 것과 달리) 단음 모드다 —
    // 한 번 음을 안정적으로 잡으면 그 음으로 조성/화음을 고정하고, 이후에 들어오는
    // 다른 소리(숨소리, 다음 음절, 잡음)에 계속 휩쓸려 바뀌지 않게 한다.
    @State private var hasCapturedNote = false
    @State private var pendingPitchClass: Int?
    @State private var pendingStreak = 0

    // 노이즈성 프레임 하나로 잘못 확정되지 않도록, 같은 pitch class가 이만큼
    // 연속 프레임(약 46ms x 3 = 140ms) 유지돼야 "이 음으로 확정"한다.
    private let captureStreakRequired = 3

    private let audioCapture = AudioCapture()
    private let melodySession = MelodySession()
    private let tonePlayer = TonePlayer()
    private let pitchSmoother = PitchSmoother()

    // 화음의 각 음을 순서대로 들려줄 때 한 음당 재생하는 길이.
    private let noteHoldDuration: Duration = .milliseconds(800)

    // 아직 부른 멜로디가 없으면 조성/화음을 알 수 없으므로, 시작음은 조성과 무관한
    // 표준 기준음 A4(440Hz) — NoteNameConverter가 쓰는 기준 주파수와 동일 — 로 고정한다.
    // 무반주로 노래할 때 첫 음을 잡기 위해 짧게 불어주는 "피치 파이프"와 같은 역할.
    private let startingNoteFrequency = 440.0
    private let startingNoteDuration: Duration = .seconds(2)

    // 재생 중(화음/시작음)엔 마이크를 완전히 무시한다 — 스피커 소리가 되먹임되는 피드백 루프 방지.
    private var isPlaybackBusy: Bool { isPlayingTone || isPlayingStartingNote }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("HarmonyUp — Phase 1~3 프로토타입")
                    .font(.headline)

                // 1. 지금 마이크가 뭘 듣고 있는지 — 파이프라인의 첫 단계(YIN)
                flowSection(step: 1, title: "실시간 피치") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusText)
                            .font(.system(.title2, design: .monospaced))
                        Text(hasCapturedNote ? "🔒 음 고정됨 — 다시 시작을 눌러야 새로 잡습니다" : "음을 안정적으로 내면 자동으로 잡습니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // 2. 지금까지 부른 멜로디로 판별된 조성 — 두 번째 단계(KeyDetector)
                flowSection(step: 2, title: "조성 판별") {
                    Text(keyText.isEmpty ? "아직 판별되지 않음 — 몇 소절 불러보세요" : keyText)
                        .foregroundStyle(keyText.isEmpty ? .secondary : .primary)
                }

                // 3. 그 조성 기준 화음 제안 + 귀로 확인 — 세 번째 단계(ChordGenerator + TonePlayer)
                flowSection(step: 3, title: "화음 제안") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(harmonyText.isEmpty ? "아직 제안 없음" : harmonyText)
                            .foregroundStyle(harmonyText.isEmpty ? .secondary : .primary)

                        HStack {
                            Button(isPlayingStartingNote ? "재생 중…" : "시작음 듣기 (A4)", action: playStartingNote)
                                .disabled(isPlaybackBusy)
                            Button(isPlayingTone ? "화음 정지" : "화음 듣기 (3도→5도)", action: toggleTonePlayback)
                                .disabled((melodySession.suggestedHarmony == nil && !isPlayingTone) || isPlayingStartingNote)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // 4. 목표음을 따라 불러서 채점 — 네 번째 단계(PitchScorer)
                flowSection(step: 4, title: "따라 부르기 채점") {
                    VStack(alignment: .leading, spacing: 12) {
                        if scoringTarget == nil {
                            Text("채점 대기 중 — 아래에서 3도/5도 중 채점할 음을 골라 시작하세요")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("목표음: \(scoringTargetNoteName) (\(scoringTarget?.interval == .third ? "3도" : "5도"))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            // 튜너 앱처럼 바늘이 좌우로 움직이는 시각적 피드백 —
                            // "몇 cent 벗어남"이라는 숫자보다 낮은지/높은지/거의 맞는지가 한눈에 들어온다.
                            PitchMeterView(
                                centsOffset: currentScore?.centsOffset,
                                isOnPitch: currentScore?.isOnPitch ?? false,
                                toleranceCents: PitchScorer.onPitchToleranceCents
                            )

                            if let score = currentScore {
                                Text(String(format: "%+.0f cent  %@", score.centsOffset, score.isOnPitch ? "✅ 정확" : "벗어남"))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(score.isOnPitch ? .green : .secondary)
                            }
                        }

                        HStack {
                            Button(
                                scoringTarget?.interval == .third ? "3도 채점 중지" : "3도 채점",
                                action: { toggleScoring(interval: .third) }
                            )
                            Button(
                                scoringTarget?.interval == .fifth ? "5도 채점 중지" : "5도 채점",
                                action: { toggleScoring(interval: .fifth) }
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(melodySession.suggestedHarmony == nil)
                    }
                }

                Button("다시 시작", role: .destructive, action: resetSession)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .onAppear(perform: startCapture)
        .onDisappear {
            tonePlaybackTask?.cancel()
            startingNoteTask?.cancel()
            audioCapture.stop()
            tonePlayer.stop()
        }
    }

    /// 파이프라인 단계를 "1. 실시간 피치"처럼 번호가 붙은 섹션으로 보여줘서,
    /// 화면만 봐도 마이크 입력 -> 조성 판별 -> 화음 제안 -> 채점으로 이어지는 전체 흐름이 드러나게 한다.
    @ViewBuilder
    private func flowSection<Content: View>(step: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(step). \(title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func startCapture() {
        do {
            try audioCapture.start { result in
                // 화음/시작음 재생 중엔 마이크 입력을 완전히 무시한다 — 안 그러면 스피커로 낸 소리가
                // 다시 마이크로 들어가서 "새로 부른 음"으로 인식되고, 거기에 또 화음이 붙는 피드백 루프가 생긴다.
                guard !isPlaybackBusy else { return }

                guard let result else {
                    pendingPitchClass = nil
                    pendingStreak = 0
                    statusText = "..."
                    return
                }

                let line = String(
                    format: "%@  %.1fHz  (%+.1f cent, 신뢰도 %.2f)",
                    result.noteName, result.frequency, result.centsOffset, result.confidence
                )
                statusText = line
                print(line) // Phase 1 완료 조건: 감지된 결과를 콘솔에 실시간 출력

                // 단음 모드: 이미 한 음을 확정했으면 조성/화음은 더 이상 갱신하지 않는다 —
                // 안 그러면 숨소리/다음 음절/잡음이 들어올 때마다 계속 바뀐다.
                // (아래 채점 로직은 이 블록 밖에서 계속 돌아간다 — 확정된 목표음을 따라 부르는 걸 들어야 하니까)
                if !hasCapturedNote {
                    // 같은 pitch class가 몇 프레임 연속 유지돼야 "진짜 이 음을 내고 있다"고 보고 확정한다.
                    if pendingPitchClass == result.pitchClass {
                        pendingStreak += 1
                    } else {
                        pendingPitchClass = result.pitchClass
                        pendingStreak = 1
                    }

                    if pendingStreak >= captureStreakRequired {
                        melodySession.record(result)
                        hasCapturedNote = true

                        if let key = melodySession.detectedKey {
                            keyText = String(format: "조성: %@ (확신도 %.2f)", key.name, key.confidence)
                        }

                        if let harmony = melodySession.suggestedHarmony {
                            let names = harmony
                                .map { NoteNameConverter.convert(frequency: $0.frequency)?.noteName ?? "?" }
                                .joined(separator: ", ")
                            harmonyText = "화음 제안: \(names)"
                        }
                    }
                }

                if let target = scoringTarget {
                    // 원본 프레임 주파수를 그대로 채점하면 비브라토/발성 흔들림 때문에 바늘이
                    // 지저분하게 튄다 — 스무딩을 거친 값으로 채점해서 "지금 대충 맞는지"가 잘 보이게 한다.
                    let smoothedFrequency = pitchSmoother.smooth(frequency: result.frequency)
                    currentScore = PitchScorer.score(sungFrequency: smoothedFrequency, targetFrequency: target.frequency)
                }
            }
        } catch {
            statusText = "마이크 시작 실패: \(error.localizedDescription)"
        }
    }

    private func toggleTonePlayback() {
        if isPlayingTone {
            tonePlaybackTask?.cancel()
            tonePlaybackTask = nil
            tonePlayer.stop()
            isPlayingTone = false
            return
        }

        // 버튼을 누른 시점의 화음으로 고정한다 — 재생 중엔 마이크를 무시하므로 어차피 갱신될 일은 없지만,
        // "다시 시작을 누르기 전까지는 이 음에 대한 화음만 듣는다"는 의도를 코드로도 명확히 드러낸다.
        guard let lockedHarmony = melodySession.suggestedHarmony, !lockedHarmony.isEmpty else { return }

        do {
            try tonePlayer.start()
            isPlayingTone = true
        } catch {
            statusText = "재생 실패: \(error.localizedDescription)"
            return
        }

        tonePlaybackTask = Task {
            await playHarmonyNotesInSequence(lockedHarmony)
        }
    }

    /// 고정된 화음의 각 음(3도, 5도)을 하나씩 순서대로 들려주는 걸 정지할 때까지 반복한다.
    private func playHarmonyNotesInSequence(_ harmony: [ChordGenerator.HarmonyNote]) async {
        while !Task.isCancelled {
            for note in harmony {
                guard !Task.isCancelled else { return }
                tonePlayer.setFrequency(note.frequency)
                try? await Task.sleep(for: noteHoldDuration)
            }
        }
    }

    /// 노래를 시작하기 전 기준음(A4)을 잠깐 들려준다 — 무반주로 노래할 때 첫 음을 잡기 위한 "피치 파이프".
    /// 화음 재생과 마찬가지로 재생 중엔 마이크를 무시해서 스피커 소리가 되먹임되는 걸 막는다.
    private func playStartingNote() {
        guard !isPlaybackBusy else { return }

        do {
            try tonePlayer.start()
            tonePlayer.setFrequency(startingNoteFrequency)
            isPlayingStartingNote = true
        } catch {
            statusText = "재생 실패: \(error.localizedDescription)"
            return
        }

        startingNoteTask = Task {
            try? await Task.sleep(for: startingNoteDuration)
            guard !Task.isCancelled else { return }
            tonePlayer.stop()
            isPlayingStartingNote = false
        }
    }

    /// 화음의 3도 또는 5도 음을 채점 목표로 고정한다. 같은 걸 다시 누르면 중지되고,
    /// 채점 중에 다른 쪽을 누르면 멈추지 않고 그쪽 목표로 바로 전환된다 — 3도/5도를
    /// 번갈아 연습할 때 매번 멈췄다 다시 시작할 필요가 없게.
    private func toggleScoring(interval: ChordGenerator.Interval) {
        if let scoringTarget, scoringTarget.interval == interval {
            self.scoringTarget = nil
            scoringTargetNoteName = ""
            currentScore = nil
            return
        }

        guard let harmony = melodySession.suggestedHarmony,
              let target = harmony.first(where: { $0.interval == interval }) else { return }
        scoringTarget = target
        scoringTargetNoteName = NoteNameConverter.convert(frequency: target.frequency)?.noteName ?? "?"
        pitchSmoother.reset() // 이전 채점(또는 다른 음)에서 쓰던 값이 새 채점에 섞여 들어가지 않도록
    }

    private func resetSession() {
        tonePlaybackTask?.cancel()
        tonePlaybackTask = nil
        startingNoteTask?.cancel()
        startingNoteTask = nil
        tonePlayer.stop()
        isPlayingTone = false
        isPlayingStartingNote = false
        scoringTarget = nil
        scoringTargetNoteName = ""
        currentScore = nil
        pitchSmoother.reset()
        melodySession.reset()
        hasCapturedNote = false
        pendingPitchClass = nil
        pendingStreak = 0
        keyText = ""
        harmonyText = ""
        statusText = "..."
    }
}
