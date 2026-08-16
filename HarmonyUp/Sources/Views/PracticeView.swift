import SwiftUI
import SwiftData
import AVFAudio
import UIKit

/// "연습" 탭 — 빠른 녹음으로 노래 한 소절을 받아 조성/화음 판별 -> 화음 청취(합성음/내 목소리) ->
/// 채점까지 한 세션의 흐름을 담당한다. 예전엔 이 화면 자체가 앱의 유일한 화면(`ContentView`)이었는데,
/// 세션 기록(`HistoryView`)을 별도 탭으로 분리하면서 이름도 역할에 맞게 바꿨다. 예전엔 "단음"/"멜로디"
/// 실시간 캡처 모드도 별도로 있었지만, 빠른 녹음이 그 기능(여러 음을 이어 부른 멜로디)을 그대로
/// 포함하면서 데이터 흐름이 더 명확해져서(녹음 완료 -> 분석 -> 결과, 프레임 단위로 상태가 섞이지
/// 않음) 하나로 통합했다.
struct PracticeView: View {
    @Environment(\.modelContext) private var modelContext

    // 빠른 녹음 전용 상태 — 녹음 전체를 모았다가 멈춘 뒤 한 번에 RecordingAnalyzer로 분석한다.
    @State private var quickRecordPhase: QuickRecordView.Phase = .idle
    @State private var quickRecordBuffer: [Float] = []
    @State private var quickRecordSampleRate: Double = 44100
    // WSOLA 피치시프트 비용(다중 음 화음 만들 때)과 결과 악보의 가로 스크롤 UX를 고려한 상한.
    private let quickRecordMaxDuration: Double = 30.0

    // 마이크가 지금 실제로 열려 있는지(오디오 엔진이 돌고 있는지)만 추적하는 내부 플래그다 —
    // beginCapturingIfNeeded()의 중복 시작 방지용일 뿐, UI 활성/비활성 판단에는 쓰지 않는다.
    // 녹음이 끝나면 곧바로 false가 되므로, "내 목소리로 화음" 같은 버튼을 이 값으로 막으면
    // 정작 다 녹음해놓고도 버튼이 눌리지 않는 버그가 생긴다(실제로 겪은 문제).
    @State private var isCapturing = false
    // 마이크 권한이 꺼진 상태는 버튼을 누르기도 전에(onAppear에서) 미리 감지해서 전용 UI로 보여준다.
    @State private var micPermissionDenied = false

    // 녹음/재생 관련 짧은 피드백 메시지 — 가드 조건에 걸렸을 때 "왜 안 되는지"를 "내 목소리로 화음"
    // 카드에 알려주는 용도로만 쓴다. 결과/성공 메시지도 여기 담긴다.
    @State private var statusText = ""
    @State private var keyText = ""
    @State private var isPlayingTone = false
    @State private var tonePlaybackTask: Task<Void, Never>?
    @State private var isPlayingStartingNote = false
    @State private var startingNoteTask: Task<Void, Never>?
    // 3도/5도를 각각 독립적으로 채점한다 — 하나 채점하다 다른 쪽으로 넘어가도
    // 이전 것의 최근 결과(latestScores)는 화면에 그대로 남아있는다. 실제로 마이크가
    // 매 순간 채점하는 대상은 하나(activeScoringInterval)뿐이지만, 그 결과와 사람이 부르는
    // 동안 쌓인 샘플은 interval별로 따로 보관해서 서로 덮어쓰지 않게 한다.
    @State private var activeScoringInterval: ChordGenerator.Interval?
    @State private var lockedScoringTargets: [ChordGenerator.Interval: ChordGenerator.HarmonyNote] = [:]
    @State private var latestScores: [ChordGenerator.Interval: PitchScorer.Score] = [:]
    @State private var scoreSampleBuffers: [ChordGenerator.Interval: [PitchScorer.Score]] = [:]

    // 첫 녹음 분석이 끝났는지 — 점진적 공개(조성+화음 카드 등장 여부) 판단에 쓴다.
    @State private var hasCapturedNote = false
    @State private var melodySteps: [MelodyStep] = []

    // 멜로디 전체의 화음 라인(3도 또는 5도)을 이어서 들려주는 재생 상태 — "도미솔을 부르면
    // 그 3도/5도를 처음부터 끝까지 이어서 들려준다"는 요청에 대응한다.
    @State private var playingMelodyLineInterval: ChordGenerator.Interval?
    @State private var melodyLineTask: Task<Void, Never>?

    // "내 목소리로 화음 만들기" — 합성음(TonePlayer) 대신 사용자 목소리를 그대로 3도/5도 위로
    // 옮겨서 재생한다. 빠른 녹음이 끝나면 녹음 전체가 그대로 여기 채워진다(applyQuickRecordResult).
    @State private var recentVoiceBuffer: [Float] = []
    @State private var recentVoiceSampleRate: Double = 44100
    private let voiceClipPlayer = VoiceClipPlayer()
    // 목소리 화음 재생 시작/끝에 적용할 페이드 길이 — 녹음 구간은 원본 파형의 임의 지점에서
    // 시작/끝나서, 그대로 재생하면 클릭음이 날 수 있다(AudioGain 참고).
    private let voiceClipFadeDuration: Double = 0.015

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
        noteName(forMIDINote: startingNoteMIDI)
    }

    private func noteName(forMIDINote midiNote: Int) -> String {
        NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midiNote))?.noteName ?? "?"
    }

    /// 기준음 선택 + 재생 — 반음씩 -/+ 누르던 Stepper는 매번 여러 번 눌러야 해서 불편하다는
    /// 피드백을 받아 드롭다운(Picker)으로 바꿨다. 목록에서 바로 원하는 음을 골라 한 번에 이동한다.
    @ViewBuilder
    private var startingNoteControls: some View {
        let picker = Picker("첫 음", selection: $startingNoteMIDI) {
            ForEach(Array(startingNoteRange), id: \.self) { midiNote in
                Text(noteName(forMIDINote: midiNote)).tag(midiNote)
            }
        }
        .pickerStyle(.menu)
        .disabled(isPlaybackBusy)

        let listenButton = Button(action: playStartingNote) {
            Label(isPlayingStartingNote ? "재생 중…" : "시작음 듣기", systemImage: isPlayingStartingNote ? "waveform" : "play.circle")
        }
        .buttonStyle(.bordered)
        .disabled(isPlaybackBusy)

        // 글자 크기를 크게 키우면(Dynamic Type) 가로로 나란히 두 컨트롤을 넣을 공간이 부족해져서
        // 버튼 텍스트가 줄바꿈되며 알약 모양이 찌그러지는 문제가 있었다 — ViewThatFits로 한 줄에
        // 안 들어가면 자동으로 세로 배치로 바뀌게 했다.
        ViewThatFits {
            HStack { picker; listenButton }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) { picker; listenButton }
        }
    }

    /// 마이크 권한이 꺼져 있을 때 캡처 영역 자리에 보여주는 전용 상태 — "왜 안 되는지" 설명하고
    /// 바로 설정 앱의 이 앱 권한 화면으로 이동할 수 있게 한다.
    @ViewBuilder
    private var micPermissionDeniedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("마이크 권한이 꺼져 있어요", systemImage: "mic.slash.fill")
                .font(Theme.Typography.subheadlineBold)
                .foregroundStyle(.orange)
            Text("설정에서 마이크 권한을 허용하면 바로 시작할 수 있어요")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label("설정 열기", systemImage: "gear")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // 재생 중(화음/시작음/멜로디 라인/내 목소리 화음)엔 마이크를 완전히 무시한다 — 스피커 소리가
    // 되먹임되는 피드백 루프 방지. isPlayingVoiceClip이 빠져 있던 게 26절 버그의 원인이었다.
    private var isPlaybackBusy: Bool {
        isPlayingTone || isPlayingStartingNote || playingMelodyLineInterval != nil || isPlayingVoiceClip
    }
    @State private var isPlayingVoiceClip = false

    // 화음이 나오는 순간(카드 2개가 한꺼번에 등장) 새로 나타난 카드로 자동 스크롤하기 위한 판정.
    // melodySession.suggestedHarmony(Optional 배열) 자체는 Equatable이 아니라서, onChange/애니메이션
    // 트리거로 쓰기 쉬운 단순 Bool로 한 번 감싼다.
    private var hasHarmony: Bool { melodySession.suggestedHarmony != nil }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        // 캡처 영역 — 여기서부터 흐름이 시작된다. 빠른 녹음이 연습의 유일한 진입점이라
                        // 카드 크롬(제목바/테두리) 없이 화면의 주인공이 되는 히어로 레이아웃을 쓴다
                        // (QuickRecordView가 스스로 대기/녹음 중 상태를 꾸민다).
                        Group {
                            if micPermissionDenied {
                                micPermissionDeniedContent
                            } else {
                                QuickRecordView(
                                    phase: quickRecordPhase,
                                    elapsed: Double(quickRecordBuffer.count) / quickRecordSampleRate,
                                    maxDuration: quickRecordMaxDuration,
                                    waveformSamples: quickRecordBuffer,
                                    onStart: startQuickRecording,
                                    onStop: stopQuickRecording,
                                    onCancel: cancelQuickRecording,
                                    onReset: resetSession
                                )
                            }
                        }
                        .id("captureCard")

                        // 조성+화음: 첫 녹음 분석이 끝나기 전엔 아예 렌더링하지 않는다(점진적 공개) —
                        // "아직 판별되지 않음" 같은 빈 상태를 계속 보여주는 대신, 관련 데이터가
                        // 생긴 뒤에만 화면에 등장하게 한다.
                        if hasCapturedNote {
                            HarmonyCard("조성과 화음", systemImage: "music.note.list") {
                                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                    Text(keyText)
                                        .font(Theme.Typography.subheadline)

                                    VStack(alignment: .leading, spacing: 4) {
                                        ForEach(Array(melodySteps.enumerated()), id: \.element.id) { index, step in
                                            MelodyStepRow(
                                                step: step,
                                                onCorrect: { pitchClass in correctMelodyStep(at: index, toPitchClass: pitchClass) },
                                                onScoreThird: { startScoringMelodyStep(at: index, interval: .third) },
                                                onScoreFifth: { startScoringMelodyStep(at: index, interval: .fifth) },
                                                onScoreBass: { startScoringMelodyStep(at: index, interval: .bass) }
                                            )
                                        }
                                    }
                                    Text("음을 눌러서 고치거나, 베이스/3도/5도로 그 스텝을 바로 채점할 수 있어요")
                                        .font(Theme.Typography.caption2)
                                        .foregroundStyle(.secondary)

                                    // 도-미-솔을 부르면 그 3도(또는 5도) 라인을 처음부터 끝까지
                                    // 이어서 들려준다 — 녹음한 멜로디 전체를 화음으로 들어보는 것.
                                    // ViewThatFits: 글자 크기를 크게 키우면 두 버튼이 한 줄에
                                    // 안 들어가서 자동으로 세로 배치로 바뀐다.
                                    ViewThatFits {
                                        HStack {
                                            thirdLineButton
                                            fifthLineButton
                                        }
                                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                            thirdLineButton
                                            fifthLineButton
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isPlayingTone || isPlayingStartingNote)

                                    startingNoteControls

                                    Button(action: toggleTonePlayback) {
                                        Label(isPlayingTone ? "화음 정지" : "화음 듣기 (3도→5도)", systemImage: isPlayingTone ? "stop.fill" : "play.fill")
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled((melodySession.suggestedHarmony == nil && !isPlayingTone) || isPlayingStartingNote)
                                }
                            }
                            .id("keyHarmonyCard")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // 내 목소리로 화음: 화음이 나오기 전엔 안 보인다(할 게 없으므로).
                        if melodySession.suggestedHarmony != nil {
                            HarmonyCard("내 목소리로 화음", systemImage: "music.mic", iconColor: Theme.voiceAccent) {
                                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                    // 버튼보다 먼저 설명을 둬서, 뭘 누르기 전에 "이게 뭘 하는 버튼인지"부터
                                    // 읽히게 한다.
                                    Text(String(format: "방금 녹음한 노래를 그대로 3도/5도로 옮겨서 들려줘요 (확보된 목소리: %.1f초)",
                                                Double(recentVoiceBuffer.count) / recentVoiceSampleRate))
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.secondary)

                                    // ViewThatFits: 버튼 3개가 한 줄에 안 들어갈 만큼 글자가 커지면
                                    // 세로 배치로 자동 전환된다.
                                    ViewThatFits {
                                        HStack {
                                            voiceThirdButton
                                            voiceFifthButton
                                            voiceFullChordButton
                                        }
                                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                            voiceThirdButton
                                            voiceFifthButton
                                            voiceFullChordButton
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    // "지금 쓸 수 있는 녹음이 있는지"만 본다 — isCapturing(마이크가 지금
                                    // 열려 있는지)로 막으면, 녹음을 다 마친 뒤(=isCapturing이 이미 false)
                                    // 정작 이 버튼을 못 누르는 문제가 있었다(실제로 겪은 버그).
                                    .disabled(recentVoiceBuffer.isEmpty || isPlaybackBusy)

                                    if !statusText.isEmpty {
                                        Text(statusText)
                                            .font(Theme.Typography.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .id("voiceHarmonyCard")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // 채점: 화음이 나오기 전엔 채점할 대상이 없으므로 안 보인다.
                        if melodySession.suggestedHarmony != nil {
                            HarmonyCard("따라 부르기 채점", systemImage: "target") {
                                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                                    scoringPanel(for: .third)
                                    Divider()
                                    scoringPanel(for: .fifth)
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding()
                    // 카드가 새로 생기거나 사라질 때 위 .transition이 실제로 애니메이션되게 한다 —
                    // 이 modifier가 없으면 SwiftUI가 즉시(애니메이션 없이) 나타나고 사라진다.
                    .animation(.easeOut(duration: 0.3), value: hasCapturedNote)
                    .animation(.easeOut(duration: 0.3), value: hasHarmony)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("연습")
                // 카드가 막 나타난 시점에 화면 아래로 스크롤해서, "방금 뭐가 생겼다"는 걸
                // 사용자가 놓치지 않고 바로 보게 한다.
                .onChange(of: hasCapturedNote) { _, appeared in
                    guard appeared else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("keyHarmonyCard", anchor: .top)
                    }
                }
                .onChange(of: hasHarmony) { _, appeared in
                    guard appeared else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("voiceHarmonyCard", anchor: .top)
                    }
                }
            }
        }
        .tint(Theme.tint) // 앱 전역 유일한 인터랙션 틴트(Theme.swift) — 버튼/피커 등에 일괄 적용
        .onAppear {
            // 버튼을 눌러보기 전에 미리 알려준다.
            micPermissionDenied = AVAudioApplication.shared.recordPermission == .denied
        }
        .onDisappear {
            tonePlaybackTask?.cancel()
            startingNoteTask?.cancel()
            melodyLineTask?.cancel()
            audioCapture.stop()
            tonePlayer.stop()
            voiceClipPlayer.stop()
            isPlayingVoiceClip = false
        }
    }

    private var voiceThirdButton: some View {
        Button {
            recordAndHarmonizeVoice(interval: .third)
        } label: {
            Label("내 목소리로 3도", systemImage: "waveform")
        }
    }

    private var voiceFifthButton: some View {
        Button {
            recordAndHarmonizeVoice(interval: .fifth)
        } label: {
            Label("내 목소리로 5도", systemImage: "waveform")
        }
    }

    private var voiceFullChordButton: some View {
        Button {
            recordAndHarmonizeFullChordWithVoice()
        } label: {
            Label("내 목소리로 전체 화음", systemImage: "waveform")
        }
    }

    private var thirdLineButton: some View {
        Button {
            toggleMelodyLinePlayback(interval: .third)
        } label: {
            Label(
                playingMelodyLineInterval == .third ? "3도 라인 정지" : "전체 3도 듣기",
                systemImage: playingMelodyLineInterval == .third ? "stop.fill" : "play.fill"
            )
        }
    }

    private var fifthLineButton: some View {
        Button {
            toggleMelodyLinePlayback(interval: .fifth)
        } label: {
            Label(
                playingMelodyLineInterval == .fifth ? "5도 라인 정지" : "전체 5도 듣기",
                systemImage: playingMelodyLineInterval == .fifth ? "stop.fill" : "play.fill"
            )
        }
    }

    /// 3도 또는 5도 하나에 대한 채점 패널 — 목표음, 바늘 미터, 시작/중지 버튼을 묶어서 보여준다.
    /// 두 패널이 서로 독립적이라 latestScores[interval]만 각자 참조하고, 다른 쪽 상태에 영향받지 않는다.
    @ViewBuilder
    private func scoringPanel(for interval: ChordGenerator.Interval) -> some View {
        let label = interval == .third ? "3도" : "5도"
        let isActive = activeScoringInterval == interval
        let target = lockedScoringTargets[interval]
        let score = latestScores[interval]

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(Theme.Typography.subheadlineBold)
                if let target {
                    Text(NoteNameConverter.convert(frequency: target.frequency)?.noteName ?? "?")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    toggleScoring(interval: interval)
                } label: {
                    Label(isActive ? "중지" : "채점", systemImage: isActive ? "stop.fill" : "target")
                }
                .buttonStyle(.bordered)
                .disabled(!isActive && melodySession.suggestedHarmony == nil)
            }

            if score == nil && target == nil {
                Text("아직 채점 안 함")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                PitchMeterView(
                    centsOffset: score?.centsOffset,
                    isOnPitch: score?.isOnPitch ?? false,
                    toleranceCents: PitchScorer.onPitchToleranceCents
                )
                if let score {
                    Text(String(format: "%+.0f cent  %@", score.centsOffset, score.isOnPitch ? "✅ 정확" : "벗어남"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(score.isOnPitch ? Theme.pitchGood : .secondary)
                }
            }
        }
    }

    /// 측정(마이크 캡처)이 꺼져 있으면 켠다. 이미 켜져 있으면 아무 것도 하지 않는다(중복 start 방지).
    /// "녹음 시작"과 "채점하기" 둘 다 이걸 호출해서, 같은 audioCapture 하나를 상황에 맞게 공유한다 —
    /// 실제로 무엇을 할지는 audioCapture의 콜백(startCaptureAfterPermissionGranted)이 그때그때의
    /// quickRecordPhase/activeScoringInterval을 보고 판단한다.
    ///
    /// 마이크 권한을 먼저 확인한다 — 거부된 상태에서 그냥 start()를 호출하면 실패 이유가 눈에 잘
    /// 안 띄었다. 여기서 미리 걸러서 전용 UI(micPermissionDeniedContent)로 보여준다.
    private func beginCapturingIfNeeded() {
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

    private func startCaptureAfterPermissionGranted() {
        do {
            try audioCapture.start { result, rawSamples, rawSampleRate in
                // 화음/시작음 재생 중엔 마이크 입력을 완전히 무시한다 — 안 그러면 스피커로 낸 소리가
                // 다시 마이크로 들어가서 "새로 부른 음"으로 인식되고, 거기에 또 화음이 붙는 피드백 루프가 생긴다.
                guard !isPlaybackBusy else { return }

                // 녹음 중엔 이 프레임을 quickRecordBuffer에 쌓기만 한다. 녹음이 끝난 뒤 "따라 부르기
                // 채점"으로 마이크가 다시 켜질 때는 quickRecordPhase가 더 이상 .recording이 아니므로
                // 이 분기를 건너뛰고 곧장 아래 채점 로직으로 간다.
                if quickRecordPhase == .recording {
                    quickRecordBuffer.append(contentsOf: rawSamples)
                    quickRecordSampleRate = rawSampleRate
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
    private func startQuickRecording() {
        quickRecordBuffer = []
        quickRecordPhase = .recording
        beginCapturingIfNeeded()
    }

    /// "녹음 그만" 버튼(또는 30초 상한 도달 시 자동 호출) — 마이크를 멈추고, 지금까지 모은 녹음
    /// 전체를 RecordingAnalyzer로 한 번에 분석한다. YIN을 윈도우마다 돌리는 무거운 계산이라
    /// Task로 감싸서 메인 스레드가 멈추지 않게 한다.
    private func stopQuickRecording() {
        guard quickRecordPhase == .recording else { return }
        audioCapture.stop()
        isCapturing = false
        quickRecordPhase = .analyzing

        let samples = quickRecordBuffer
        let rate = quickRecordSampleRate
        Task {
            let analyzed = RecordingAnalyzer.analyze(recordingSamples: samples, sampleRate: rate)
            applyQuickRecordResult(analyzed)
        }
    }

    /// "취소"(X) 버튼 — 참고 디자인의 Discard와 같은 역할. "녹음 그만"과 달리 분석을 아예
    /// 돌리지 않고 지금까지 모은 소리를 그냥 버린 뒤 대기 상태로 되돌아간다.
    private func cancelQuickRecording() {
        guard quickRecordPhase == .recording else { return }
        audioCapture.stop()
        isCapturing = false
        quickRecordBuffer = []
        quickRecordPhase = .idle
    }

    /// RecordingAnalyzer의 배치 분석 결과를, 기존 UI가 그대로 소비할 수 있는 상태로 반영한다.
    private func applyQuickRecordResult(_ analyzed: RecordingAnalyzer.AnalyzedRecording) {
        guard !analyzed.notes.isEmpty else {
            quickRecordPhase = .error("노래가 인식되지 않았어요 — 더 또렷하게 불러서 다시 녹음해주세요")
            return
        }

        melodySession.reset()

        // 1단계: 세그멘테이션된 음을 순서대로 melodySession에 그대로 먹인다 — correctMelodyStep(at:toPitchClass:)가
        // 수정 하나를 반영할 때 쓰는 것과 같은 합성 DetectionResult 패턴이다. 이렇게 하면 melodySession의
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

        guard let key = melodySession.detectedKey else {
            quickRecordPhase = .error("조성을 판별하지 못했어요 — 조금 더 길게 불러서 다시 녹음해주세요")
            return
        }
        keyText = String(format: "조성: %@ (확신도 %.2f)", key.name, key.confidence)

        // 2단계: 화면에 보여줄 스텝별 화음은 correctMelodyStep이 수정 후 하는 것과 같은 이유로,
        // 녹음 전체를 다 보고 확정한 "최종" 조성 기준으로 한 번에 다시 계산한다 — 실시간 캡처처럼
        // "그때까지 들은 것만으로 추측한 조성"을 스텝마다 다르게 쓰면, 이미 다 끝난 녹음을 배치로
        // 분석하는 이 경로에서는 앞부분 스텝의 화음이 뒤늦게 밝혀진 진짜 조성과 어긋나 보일 수 있다.
        melodySteps = analyzed.notes.map { note in
            let frequency = NoteNameConverter.frequency(forMIDINote: note.midiNote)
            let noteName = NoteNameConverter.convert(frequency: frequency)?.noteName ?? "?"
            let harmony = ChordGenerator.generateHarmony(melodyFrequency: frequency, key: key)
            return MelodyStep(noteName: noteName, midiNote: note.midiNote, harmonyVoices: MelodyStep.harmonyVoices(from: harmony), onsetTime: note.onsetTime, duration: note.duration)
        }

        // "내 목소리로 화음"/채점 카드가 그대로 재사용하는 recentVoiceBuffer를 녹음 전체로 채운다 —
        // 이후 3도/5도/전체 화음 버튼을 누르면 이 전체 녹음이 그대로 피치시프트된다.
        recentVoiceBuffer = analyzed.voiceSamples
        recentVoiceSampleRate = analyzed.sampleRate

        hasCapturedNote = true
        quickRecordPhase = .result(noteCount: analyzed.notes.count)
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
        // "다시 녹음하기 전까지는 이 음에 대한 화음만 듣는다"는 의도를 코드로도 명확히 드러낸다.
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

    /// 멜로디 각 스텝을 현재(최신) 조성 기준으로 다시 계산해서, interval(3도 또는 5도) 라인 전체를
    /// 순서대로 반환한다. 저장된 harmonyVoices 대신 매번 새로 계산하는 이유는, 사용자가 중간에
    /// 스텝을 고쳐서 조성이 바뀌었을 수도 있으니 재생 시점 기준으로 항상 최신 상태를 들려주기 위함이다.
    private func melodyHarmonyLine(interval: ChordGenerator.Interval) -> [ChordGenerator.HarmonyNote] {
        guard let key = melodySession.detectedKey else { return [] }
        return melodySteps.compactMap { step in
            let frequency = NoteNameConverter.frequency(forMIDINote: step.midiNote)
            return ChordGenerator.generateHarmony(melodyFrequency: frequency, key: key)?.first { $0.interval == interval }
        }
    }

    /// 멜로디 전체의 화음 라인(3도 또는 5도)을 처음부터 끝까지 한 바퀴 이어서 들려준다.
    /// 화음 듣기(단일 목표음)와 달리 끝나면 자동으로 멈춘다 — 멜로디는 길이가 정해져 있어서
    /// 무한 반복하면 오히려 "언제 끝났는지" 헷갈린다.
    private func toggleMelodyLinePlayback(interval: ChordGenerator.Interval) {
        if playingMelodyLineInterval == interval {
            melodyLineTask?.cancel()
            melodyLineTask = nil
            tonePlayer.stop()
            playingMelodyLineInterval = nil
            return
        }

        let line = melodyHarmonyLine(interval: interval)
        guard !line.isEmpty else { return }

        melodyLineTask?.cancel()

        do {
            try tonePlayer.start()
            playingMelodyLineInterval = interval
        } catch {
            statusText = "재생 실패: \(error.localizedDescription)"
            return
        }

        melodyLineTask = Task {
            for note in line {
                guard !Task.isCancelled else { return }
                tonePlayer.setFrequency(note.frequency)
                try? await Task.sleep(for: noteHoldDuration)
            }
            guard !Task.isCancelled else { return }
            tonePlayer.stop()
            playingMelodyLineInterval = nil
        }
    }

    /// 마지막으로 잡은 음을 기준으로, 목표 interval(3도/5도) 위 주파수까지의 배율(pitchRatio)을 구한다.
    private func pitchRatio(toInterval interval: ChordGenerator.Interval) -> Double? {
        guard let lastFrequency = melodySession.lastNote?.frequency,
              let harmony = melodySession.suggestedHarmony,
              let target = harmony.first(where: { $0.interval == interval }) else { return nil }
        return target.frequency / lastFrequency
    }

    /// "내 목소리로 화음 만들기" — 방금 녹음한 소리(recentVoiceBuffer)를 3도/5도 위로
    /// 피치 시프트해서, 합성음이 아니라 사용자 자신의 목소리 톤으로 화음을 즉시 들려준다.
    private func recordAndHarmonizeVoice(interval: ChordGenerator.Interval) {
        // 버튼을 눌렀는데 아무 것도 안 바뀌는 것처럼 보이는 문제를 막기 위해, 막힌 이유를
        // 항상 statusText로 알려준다 — 조용히 return만 하면 "눌러도 반응 없음"으로 보인다.
        guard !isPlaybackBusy else {
            statusText = "다른 소리가 재생 중이에요 — 끝난 뒤 다시 눌러주세요"
            return
        }
        guard melodySession.suggestedHarmony != nil else {
            statusText = "아직 화음이 없어요 — 먼저 녹음해주세요"
            return
        }
        guard let ratio = pitchRatio(toInterval: interval) else {
            statusText = "목표음을 계산하지 못했어요"
            return
        }
        guard !recentVoiceBuffer.isEmpty else {
            statusText = "아직 녹음된 목소리가 없어요 — 먼저 녹음해주세요"
            return
        }

        // PitchShifter.shift는 그레인마다 상관관계를 계산하는 WSOLA라 가볍지 않다 — 버튼을 누른
        // 그 자리에서(메인 스레드) 바로 돌리면 그동안 화면이 멈춰서, 실기기에서 "제스처 게이트
        // 타임아웃"(시스템이 터치 응답을 못 받아 경고) 로그와 함께 버튼이 안 눌리는 것처럼
        // 보이는 문제가 있었다. Task로 감싸서 백그라운드로 미루고, 계산이 끝난 뒤에만
        // 화면(statusText)과 오디오 재생을 갱신한다.
        let recorded = recentVoiceBuffer
        let rate = recentVoiceSampleRate
        let rootFrequency = melodySession.lastNote?.frequency
        statusText = "화음 만드는 중…"

        Task {
            let shifted = PitchShifter.shift(samples: recorded, pitchRatio: ratio, sampleRate: rate, expectedFrequency: rootFrequency)
            // 마이크로 녹음한 원본은 보통 피크가 한참 낮게 들어와서(합성음보다 훨씬 작게 들림),
            // 재생 전에 거의 꽉 차는 수준(0.95)까지 디지털 게인을 올려서 체감 음량을 키운다.
            let normalized = AudioGain.normalize(shifted)
            // 녹음 버퍼는 원본 파형의 임의 지점에서 시작/끝나 있어서, 그대로 재생하면 시작/끝에서
            // "뚝" 하는 클릭음이 날 수 있다 — 양 끝을 짧게(15ms) 페이드해서 없앤다.
            let cleaned = AudioGain.applyFadeInOut(normalized, fadeSampleCount: Int(rate * voiceClipFadeDuration))
            do {
                // 재생 중엔 마이크를 무시해야 한다(다른 재생 함수들과 동일한 콜앤리스폰스 규칙) —
                // 안 그러면 스피커로 나온 화음을 마이크가 다시 듣고 "새 멜로디 음"으로 착각해서
                // 조성/화음 판단이 오염된다(26절). 재생이 실제로 끝난 뒤에만 다시 켠다.
                isPlayingVoiceClip = true
                try voiceClipPlayer.play(samples: cleaned, sampleRate: rate) {
                    isPlayingVoiceClip = false
                }
                statusText = "내 목소리로 만든 화음을 재생합니다"
            } catch {
                isPlayingVoiceClip = false
                statusText = "재생 실패: \(error.localizedDescription)"
            }
        }
    }

    /// "내 목소리로 3도"/"5도"는 한 음씩만 들려주는데, 이건 원음(그대로) + 3도로 옮긴 목소리 +
    /// 5도로 옮긴 목소리를 한꺼번에 섞어서 진짜 3화음처럼 들려준다.
    private func recordAndHarmonizeFullChordWithVoice() {
        guard !isPlaybackBusy else {
            statusText = "다른 소리가 재생 중이에요 — 끝난 뒤 다시 눌러주세요"
            return
        }
        guard melodySession.suggestedHarmony != nil else {
            statusText = "아직 화음이 없어요 — 먼저 녹음해주세요"
            return
        }
        guard let thirdRatio = pitchRatio(toInterval: .third),
              let fifthRatio = pitchRatio(toInterval: .fifth) else {
            statusText = "목표음을 계산하지 못했어요"
            return
        }
        guard !recentVoiceBuffer.isEmpty else {
            statusText = "아직 녹음된 목소리가 없어요 — 먼저 녹음해주세요"
            return
        }

        let recorded = recentVoiceBuffer
        let rate = recentVoiceSampleRate
        let rootFrequency = melodySession.lastNote?.frequency
        statusText = "전체 화음 만드는 중…"

        Task {
            // 원음(비율 1.0, 시프트 없이 그대로) + 3도 + 5도로 각각 옮긴 목소리를 만든다.
            let third = PitchShifter.shift(samples: recorded, pitchRatio: thirdRatio, sampleRate: rate, expectedFrequency: rootFrequency)
            let fifth = PitchShifter.shift(samples: recorded, pitchRatio: fifthRatio, sampleRate: rate, expectedFrequency: rootFrequency)
            // 세 트랙을 섞으면 각자보다 커지므로, mixAndNormalize가 합친 뒤 다시 피크 기준으로
            // 정규화해서 서로 다른 음 개수(1개 vs 3개)에 상관없이 항상 비슷한 체감 음량이 되게 한다.
            let mixed = AudioGain.mixAndNormalize([recorded, third, fifth])
            let cleaned = AudioGain.applyFadeInOut(mixed, fadeSampleCount: Int(rate * voiceClipFadeDuration))

            do {
                isPlayingVoiceClip = true
                try voiceClipPlayer.play(samples: cleaned, sampleRate: rate) {
                    isPlayingVoiceClip = false
                }
                statusText = "내 목소리로 만든 전체 화음을 재생합니다"
            } catch {
                isPlayingVoiceClip = false
                statusText = "재생 실패: \(error.localizedDescription)"
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
    /// 번갈아 연습할 때 매번 멈췄다 다시 시작할 필요가 없게. 각자의 최근 결과(latestScores)는
    /// 전환하거나 중지해도 지워지지 않고 화면에 남아있는다 — 지워지는 건 "지금 채점 중"인지 여부뿐.
    private func toggleScoring(interval: ChordGenerator.Interval) {
        if activeScoringInterval == interval {
            finalizeCurrentAttempt(interval: interval)
            activeScoringInterval = nil
            return
        }

        // 다른 쪽을 채점하고 있었다면 그 시도부터 기록으로 남긴다.
        if let previous = activeScoringInterval {
            finalizeCurrentAttempt(interval: previous)
        }

        guard let harmony = melodySession.suggestedHarmony,
              let target = harmony.first(where: { $0.interval == interval }) else { return }

        lockedScoringTargets[interval] = target
        activeScoringInterval = interval
        pitchSmoother.reset() // 이전 채점(또는 다른 음)에서 쓰던 값이 새 채점에 섞여 들어가지 않도록

        // "채점하기"를 눌렀는데 마이크가 꺼져 있으면 자동으로 켜준다.
        beginCapturingIfNeeded()
    }

    /// 특정 스텝(마지막 음이 아니어도 됨)을 골라 그 자리에서 바로 채점을 시작한다.
    /// toggleScoring(interval:)은 항상 melodySession.suggestedHarmony(마지막 음 기준)만 봤어서
    /// 멜로디가 여러 개 쌓여도 마지막 스텝만 채점할 수 있었다 — 이건 그 제약을 없앤 버전이다.
    private func startScoringMelodyStep(at index: Int, interval: ChordGenerator.Interval) {
        guard melodySteps.indices.contains(index), let key = melodySession.detectedKey else { return }

        let frequency = NoteNameConverter.frequency(forMIDINote: melodySteps[index].midiNote)
        guard let harmony = ChordGenerator.generateHarmony(melodyFrequency: frequency, key: key),
              let target = harmony.first(where: { $0.interval == interval }) else { return }

        if let previous = activeScoringInterval {
            finalizeCurrentAttempt(interval: previous)
        }

        lockedScoringTargets[interval] = target
        activeScoringInterval = interval
        pitchSmoother.reset()
        beginCapturingIfNeeded()
    }

    /// 지금까지 쌓인 채점 샘플들을 하나의 요약(PracticeSummary.Aggregate)으로 압축해서
    /// SwiftData에 저장하고, 다음 시도를 위해 그 interval의 샘플 버퍼만 비운다.
    private func finalizeCurrentAttempt(interval: ChordGenerator.Interval) {
        defer { scoreSampleBuffers[interval] = [] }

        guard let target = lockedScoringTargets[interval],
              let samples = scoreSampleBuffers[interval],
              let aggregate = PracticeSummary.aggregate(scores: samples) else { return }

        let attempt = PracticeAttempt(
            date: Date(),
            intervalRawValue: interval == .third ? "third" : "fifth",
            targetNoteName: NoteNameConverter.convert(frequency: target.frequency)?.noteName ?? "?",
            sampleCount: aggregate.sampleCount,
            onPitchRatio: aggregate.onPitchRatio,
            averageAbsCentsOffset: aggregate.averageAbsCentsOffset
        )
        modelContext.insert(attempt)
    }

    // 수정된 음도 조성 판별 가중치에서 다른 음들과 동등하게 취급되도록(AudioCapture의
    // bufferSize 2048 / 44.1kHz ≈ 46ms 프레임 길이를 그대로 흉내낸다).
    private let approximateFrameDuration = 0.046

    /// 잘못 잡힌 음을 사용자가 직접 골라 고친다. 같은 옥타브 안에서 pitch class만 바꾸고
    /// (F#3 -> G3처럼), MelodySession의 조성 판별 누적치도 같이 갱신한 뒤, 이 수정으로 조성이
    /// 달라졌을 수 있으니 화면에 보이는 모든 스텝의 화음을 다시 계산한다.
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
            frameDuration: approximateFrameDuration,
            samples: [],
            sampleRate: 44100
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
            let harmony = ChordGenerator.generateHarmony(melodyFrequency: frequency, key: key)
            melodySteps[i].harmonyVoices = MelodyStep.harmonyVoices(from: harmony)
        }
    }

    private func resetSession() {
        if let active = activeScoringInterval {
            finalizeCurrentAttempt(interval: active) // 리셋 직전까지의 채점 시도도 버리지 않고 기록으로 남긴다
        }

        tonePlaybackTask?.cancel()
        tonePlaybackTask = nil
        startingNoteTask?.cancel()
        startingNoteTask = nil
        melodyLineTask?.cancel()
        melodyLineTask = nil
        tonePlayer.stop()
        voiceClipPlayer.stop()
        isPlayingTone = false
        isPlayingStartingNote = false
        playingMelodyLineInterval = nil
        isPlayingVoiceClip = false
        recentVoiceBuffer = []
        activeScoringInterval = nil
        lockedScoringTargets = [:]
        latestScores = [:]
        scoreSampleBuffers = [:]
        pitchSmoother.reset()
        melodySession.reset()
        hasCapturedNote = false
        melodySteps = []
        keyText = ""
        statusText = ""
        quickRecordPhase = .idle
        quickRecordBuffer = []
    }
}
