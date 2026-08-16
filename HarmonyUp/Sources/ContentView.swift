import SwiftUI
import SwiftData

/// 마지막으로 확정된 한 음과, 그 시점 조성 기준으로 만든 화음 — 멜로디 모드에서
/// 부른 음마다 하나씩 쌓아서 "곡 전체를 부르면 순서대로 화음이 나오는" 흐름을 보여준다.
private struct MelodyStep: Identifiable {
    let id = UUID()
    var noteName: String
    var midiNote: Int      // 옥타브까지 포함한 실제 MIDI 노트 — 수정 시 같은 옥타브 안에서 pitch class만 바꾸는 데 쓴다.
    var harmonyNames: String?
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PracticeAttempt.date, order: .reverse) private var attempts: [PracticeAttempt]

    enum SessionMode: String, CaseIterable, Identifiable {
        case single = "단음"
        case melody = "멜로디"
        var id: String { rawValue }
    }
    @State private var sessionMode: SessionMode = .single

    // 예전엔 화면이 뜨자마자 자동으로 마이크를 켰는데, 사용자가 원하는 타이밍에
    // 직접 "측정 시작"을 눌러야 캡처가 시작되도록 바꿨다 — 준비되기 전에 소리가 잡히는 걸 방지.
    @State private var isCapturing = false

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
    @State private var scoreSamples: [PitchScorer.Score] = []

    // 지금은(향후 곡 전체를 듣고 여러 화음을 뽑는 것과 달리) 단음 모드다 —
    // 한 번 음을 안정적으로 잡으면 그 음으로 조성/화음을 고정하고, 이후에 들어오는
    // 다른 소리(숨소리, 다음 음절, 잡음)에 계속 휩쓸려 바뀌지 않게 한다.
    @State private var hasCapturedNote = false
    @State private var pendingPitchClass: Int?
    @State private var pendingStreak = 0

    // 멜로디 모드에서만 쓴다 — 직전에 확정한 음의 pitch class를 기억해서,
    // "같은 음을 계속 홀드하는 것"과 "다음 음으로 넘어간 것"을 구분한다.
    @State private var lastCapturedPitchClass: Int?
    @State private var melodySteps: [MelodyStep] = []

    // 노이즈성 프레임 하나로 잘못 확정되지 않도록, 같은 pitch class가 이만큼
    // 연속 프레임(약 46ms x 3 = 140ms) 유지돼야 "이 음으로 확정"한다.
    private let captureStreakRequired = 3

    private let audioCapture = AudioCapture()
    private let melodySession = MelodySession()
    private let tonePlayer = TonePlayer()
    private let pitchSmoother = PitchSmoother()

    // 화음의 각 음을 순서대로 들려줄 때 한 음당 재생하는 길이.
    private let noteHoldDuration: Duration = .milliseconds(800)

    // 시작음(무반주로 노래할 때 첫 음을 잡기 위해 짧게 불어주는 "피치 파이프")의 MIDI 노트 번호.
    // 곡마다 부르기 편한 음이 다르므로 A4(440Hz, MIDI 69)를 기본값으로 하되 직접 고를 수 있게 한다.
    @State private var startingNoteMIDI = 69
    private let startingNoteRange = 48...84 // C3~C6, 일반적인 발성 범위를 넉넉히 커버
    private let startingNoteDuration: Duration = .seconds(2)

    private var startingNoteName: String {
        NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: startingNoteMIDI))?.noteName ?? "?"
    }

    // 재생 중(화음/시작음)엔 마이크를 완전히 무시한다 — 스피커 소리가 되먹임되는 피드백 루프 방지.
    private var isPlaybackBusy: Bool { isPlayingTone || isPlayingStartingNote }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("HarmonyUp — Phase 1~3 프로토타입")
                    .font(.headline)

                Picker("모드", selection: $sessionMode) {
                    ForEach(SessionMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: sessionMode) { _, _ in resetSession() } // 모드가 바뀌면 상태가 섞이지 않게 항상 리셋

                // 1. 지금 마이크가 뭘 듣고 있는지 — 파이프라인의 첫 단계(YIN)
                flowSection(step: 1, title: "실시간 피치") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button(isCapturing ? "측정 중지" : "측정 시작", action: toggleCapture)
                            .buttonStyle(.borderedProminent)

                        Text(statusText)
                            .font(.system(.title2, design: .monospaced))
                        Text(isCapturing ? singleNoteStatusHint : "측정 시작을 눌러야 마이크가 켜집니다")
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
                        if sessionMode == .melody {
                            if melodySteps.isEmpty {
                                Text("아직 잡은 음 없음")
                                    .foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(Array(melodySteps.enumerated()), id: \.element.id) { index, step in
                                        HStack {
                                            // 실시간 검출이 틀렸을 때(예: F#3으로 잘못 잡힘) 눌러서 직접 고칠 수 있다.
                                            Menu {
                                                ForEach(0..<12, id: \.self) { pitchClass in
                                                    Button(NoteNameConverter.pitchClassName(pitchClass)) {
                                                        correctMelodyStep(at: index, toPitchClass: pitchClass)
                                                    }
                                                }
                                            } label: {
                                                Text("\(step.noteName) ✏️")
                                                    .font(.system(.body, design: .monospaced))
                                            }
                                            Text("→ \(step.harmonyNames ?? "온음계 밖")")
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                Text("음을 눌러서 잘못 잡힌 음을 고칠 수 있어요")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text(harmonyText.isEmpty ? "아직 제안 없음" : harmonyText)
                                .foregroundStyle(harmonyText.isEmpty ? .secondary : .primary)
                        }

                        HStack {
                            Stepper(value: $startingNoteMIDI, in: startingNoteRange) {
                                Text("첫 음: \(startingNoteName)")
                                    .font(.system(.body, design: .monospaced))
                            }
                            .disabled(isPlaybackBusy)
                        }

                        HStack {
                            Button(isPlayingStartingNote ? "재생 중…" : "시작음 듣기", action: playStartingNote)
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

                // 5. 지금까지 저장된 채점 시도들의 요약 — PRD 3.2.3 "정확도 요약 + 자주 벗어난 화음 유형"
                flowSection(step: 5, title: "세션 기록") {
                    VStack(alignment: .leading, spacing: 10) {
                        if attempts.isEmpty {
                            Text("아직 기록 없음 — 채점을 중지하거나 다른 음으로 바꾸면 이번 시도가 저장됩니다")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 24) {
                                intervalSummary(label: "3도", list: thirdAttempts)
                                intervalSummary(label: "5도", list: fifthAttempts)
                            }

                            if let message = weakerIntervalMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            Divider()

                            ForEach(attempts.prefix(5), id: \.persistentModelID) { attempt in
                                HStack {
                                    Text("\(attempt.targetNoteName) (\(attempt.intervalRawValue == "third" ? "3도" : "5도"))")
                                    Spacer()
                                    Text(String(format: "%.0f%% 정확", attempt.onPitchRatio * 100))
                                    Text(String(format: "평균 ±%.0fcent", attempt.averageAbsCentsOffset))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                }

                Button("다시 시작", role: .destructive, action: resetSession)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .onDisappear {
            tonePlaybackTask?.cancel()
            startingNoteTask?.cancel()
            audioCapture.stop()
            tonePlayer.stop()
        }
    }

    private var singleNoteStatusHint: String {
        switch sessionMode {
        case .single:
            return hasCapturedNote ? "🔒 음 고정됨 — 다시 시작을 눌러야 새로 잡습니다" : "음을 안정적으로 내면 자동으로 잡습니다"
        case .melody:
            return "음을 계속 이어 부르면 음마다 화음이 순서대로 쌓입니다"
        }
    }

    private var thirdAttempts: [PracticeAttempt] { attempts.filter { $0.intervalRawValue == "third" } }
    private var fifthAttempts: [PracticeAttempt] { attempts.filter { $0.intervalRawValue == "fifth" } }

    private func averageOnPitchRatio(_ list: [PracticeAttempt]) -> Double? {
        guard !list.isEmpty else { return nil }
        return list.map(\.onPitchRatio).reduce(0, +) / Double(list.count)
    }

    /// 3도/5도 평균 정확도 차이가 뚜렷하면(10%p 이상) 어느 쪽에서 더 자주 벗어나는지 알려준다 —
    /// PRD 페르소나 시나리오의 "5도 화음에서 정확도가 낮음을 확인" 같은 걸 구현한 것.
    private var weakerIntervalMessage: String? {
        guard let thirdAverage = averageOnPitchRatio(thirdAttempts),
              let fifthAverage = averageOnPitchRatio(fifthAttempts),
              abs(thirdAverage - fifthAverage) > 0.1 else { return nil }
        return thirdAverage < fifthAverage ? "3도 화음에서 더 자주 벗어나는 편이에요" : "5도 화음에서 더 자주 벗어나는 편이에요"
    }

    @ViewBuilder
    private func intervalSummary(label: String, list: [PracticeAttempt]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let average = averageOnPitchRatio(list) {
                Text(String(format: "%.0f%% (%d회)", average * 100, list.count))
                    .font(.system(.body, design: .monospaced))
            } else {
                Text("기록 없음").font(.caption).foregroundStyle(.secondary)
            }
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

    /// "측정 시작/중지" 버튼에 연결된다. AudioCapture는 stop() 이후 다시 start()해도
    /// 안전하게 재사용 가능하도록 만들어져 있어서(탭을 새로 걸고 엔진을 다시 돌림),
    /// 버튼을 여러 번 눌러도 문제없다.
    private func toggleCapture() {
        if isCapturing {
            audioCapture.stop()
            isCapturing = false
            statusText = "측정 중지됨"
            return
        }

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

                // 단음 모드에서는 이미 한 음을 확정했으면 더 이상 새 음을 잡지 않는다 —
                // 안 그러면 숨소리/다음 음절/잡음이 들어올 때마다 계속 바뀐다.
                // 멜로디 모드에서는 이 가드가 없다 — 음이 바뀔 때마다 계속 새로 잡아야 하니까.
                // (아래 채점 로직은 이 블록 밖에서 계속 돌아간다 — 확정된 목표음을 따라 부르는 걸 들어야 하니까)
                let shouldEvaluateCapture = sessionMode == .melody || !hasCapturedNote

                if shouldEvaluateCapture {
                    // 같은 pitch class가 몇 프레임 연속 유지돼야 "진짜 이 음을 내고 있다"고 보고 확정한다.
                    if pendingPitchClass == result.pitchClass {
                        pendingStreak += 1
                    } else {
                        pendingPitchClass = result.pitchClass
                        pendingStreak = 1
                    }

                    // 단음 모드: 아직 하나도 안 잡았으면 이번이 새 음.
                    // 멜로디 모드: 직전에 잡은 음과 pitch class가 다르면 새 음(같은 음을 계속 홀드하는 건 무시).
                    let isNewNote = sessionMode == .melody
                        ? result.pitchClass != lastCapturedPitchClass
                        : !hasCapturedNote

                    if pendingStreak >= captureStreakRequired && isNewNote {
                        melodySession.record(result)
                        hasCapturedNote = true
                        lastCapturedPitchClass = result.pitchClass

                        if let key = melodySession.detectedKey {
                            keyText = String(format: "조성: %@ (확신도 %.2f)", key.name, key.confidence)
                        }

                        let harmonyNames = melodySession.suggestedHarmony.map { harmony in
                            harmony
                                .map { NoteNameConverter.convert(frequency: $0.frequency)?.noteName ?? "?" }
                                .joined(separator: ", ")
                        }

                        if sessionMode == .melody {
                            let midiNote = Int(NoteNameConverter.exactMIDINote(forFrequency: result.frequency).rounded())
                            melodySteps.append(MelodyStep(noteName: result.noteName, midiNote: midiNote, harmonyNames: harmonyNames))
                        } else if let harmonyNames {
                            harmonyText = "화음 제안: \(harmonyNames)"
                        }
                    }
                }

                if let target = scoringTarget {
                    // 원본 프레임 주파수를 그대로 채점하면 비브라토/발성 흔들림 때문에 바늘이
                    // 지저분하게 튄다 — 스무딩을 거친 값으로 채점해서 "지금 대충 맞는지"가 잘 보이게 한다.
                    let smoothedFrequency = pitchSmoother.smooth(frequency: result.frequency)
                    let score = PitchScorer.score(sungFrequency: smoothedFrequency, targetFrequency: target.frequency)
                    currentScore = score
                    if let score {
                        scoreSamples.append(score) // 이번 시도가 끝나면 PracticeSummary로 압축해서 저장한다
                    }
                }
            }
            isCapturing = true
            statusText = "..."
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

    /// 노래를 시작하기 전 사용자가 고른 기준음을 잠깐 들려준다 — 무반주로 노래할 때
    /// 첫 음을 잡기 위한 "피치 파이프". 화음 재생과 마찬가지로 재생 중엔 마이크를 무시해서
    /// 스피커 소리가 되먹임되는 걸 막는다.
    private func playStartingNote() {
        guard !isPlaybackBusy else { return }

        do {
            try tonePlayer.start()
            tonePlayer.setFrequency(NoteNameConverter.frequency(forMIDINote: startingNoteMIDI))
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
        let isStoppingSameInterval = scoringTarget?.interval == interval

        // 지금까지 채점 중이던 시도(꺼지든, 다른 음으로 바뀌든)가 있으면 기록으로 남긴다.
        if scoringTarget != nil {
            finalizeCurrentAttempt()
        }

        if isStoppingSameInterval {
            scoringTarget = nil
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

    /// 지금까지 쌓인 채점 샘플들을 하나의 요약(PracticeSummary.Aggregate)으로 압축해서
    /// SwiftData에 저장하고, 다음 시도를 위해 샘플 버퍼를 비운다.
    private func finalizeCurrentAttempt() {
        defer { scoreSamples = [] }

        guard let target = scoringTarget,
              let aggregate = PracticeSummary.aggregate(scores: scoreSamples) else { return }

        let attempt = PracticeAttempt(
            date: Date(),
            intervalRawValue: target.interval == .third ? "third" : "fifth",
            targetNoteName: scoringTargetNoteName,
            sampleCount: aggregate.sampleCount,
            onPitchRatio: aggregate.onPitchRatio,
            averageAbsCentsOffset: aggregate.averageAbsCentsOffset
        )
        modelContext.insert(attempt)
    }

    // 캡처할 때 쓰는 실제 프레임 길이와 맞춰준다 — 수정된 음도 조성 판별 가중치에서
    // 다른 음들과 동등하게 취급되도록 (AudioCapture의 bufferSize 2048 / 44.1kHz ≈ 46ms).
    private let approximateFrameDuration = 0.046

    /// 멜로디 모드에서 잘못 잡힌 음을 사용자가 직접 골라 고친다. 같은 옥타브 안에서
    /// pitch class만 바꾸고(F#3 -> G3처럼), MelodySession의 조성 판별 누적치도 같이 갱신한 뒤,
    /// 이 수정으로 조성이 달라졌을 수 있으니 화면에 보이는 모든 스텝의 화음을 다시 계산한다.
    private func correctMelodyStep(at index: Int, toPitchClass newPitchClass: Int) {
        guard melodySteps.indices.contains(index) else { return }

        let oldMIDINote = melodySteps[index].midiNote
        let newMIDINote = oldMIDINote - oldMIDINote.mod(12) + newPitchClass
        let newFrequency = NoteNameConverter.frequency(forMIDINote: newMIDINote)
        guard let newNote = NoteNameConverter.convert(frequency: newFrequency) else { return }

        let corrected = AudioCapture.DetectionResult(
            frequency: newFrequency,
            noteName: newNote.noteName,
            centsOffset: 0,
            confidence: 1.0,
            pitchClass: newNote.pitchClass,
            frameDuration: approximateFrameDuration
        )
        melodySession.correctNote(at: index, to: corrected)

        melodySteps[index].noteName = newNote.noteName
        melodySteps[index].midiNote = newMIDINote

        guard let key = melodySession.detectedKey else { return }
        keyText = String(format: "조성: %@ (확신도 %.2f)", key.name, key.confidence)

        // 조성이 바뀌었을 수 있으므로, 지금까지 쌓인 스텝 전부를 최신 조성 기준으로 다시 계산한다 —
        // 그래야 화면에 보이는 시퀀스가 서로 다른 조성 가정을 섞어 보여주지 않는다.
        for i in melodySteps.indices {
            let frequency = NoteNameConverter.frequency(forMIDINote: melodySteps[i].midiNote)
            if let harmony = ChordGenerator.generateHarmony(melodyFrequency: frequency, key: key) {
                melodySteps[i].harmonyNames = harmony
                    .map { NoteNameConverter.convert(frequency: $0.frequency)?.noteName ?? "?" }
                    .joined(separator: ", ")
            } else {
                melodySteps[i].harmonyNames = nil
            }
        }
    }

    private func resetSession() {
        if scoringTarget != nil {
            finalizeCurrentAttempt() // 리셋 직전까지의 채점 시도도 버리지 않고 기록으로 남긴다
        }

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
        lastCapturedPitchClass = nil
        melodySteps = []
        keyText = ""
        harmonyText = ""
        statusText = "..."
    }
}
