import SwiftUI
import SwiftData
import AVFAudio
import UIKit

/// "연습" 탭 — 마이크 캡처 -> 조성/화음 판별 -> 화음 청취(합성음/내 목소리) -> 채점까지
/// 한 세션의 흐름을 담당한다. 예전엔 이 화면 자체가 앱의 유일한 화면(`ContentView`)이었는데,
/// 세션 기록(`HistoryView`)을 별도 탭으로 분리하면서 이름도 역할에 맞게 바꿨다.
struct PracticeView: View {
    @Environment(\.modelContext) private var modelContext

    enum SessionMode: String, CaseIterable, Identifiable {
        case quickRecord = "빠른 녹음"
        case single = "단음"
        case melody = "멜로디"
        var id: String { rawValue }
    }
    @State private var sessionMode: SessionMode = .quickRecord

    // 빠른 녹음(quickRecord) 전용 상태 — 단음/멜로디처럼 프레임마다 바로 확정하지 않고,
    // 녹음 전체를 모았다가 멈춘 뒤 한 번에 RecordingAnalyzer로 분석한다.
    @State private var quickRecordPhase: QuickRecordView.Phase = .idle
    @State private var quickRecordBuffer: [Float] = []
    @State private var quickRecordSampleRate: Double = 44100
    // WSOLA 피치시프트 비용(다중 음 화음 만들 때)과 결과 악보의 가로 스크롤 UX를 고려한 상한.
    private let quickRecordMaxDuration: Double = 30.0

    // 예전엔 화면이 뜨자마자 자동으로 마이크를 켰는데, 사용자가 원하는 타이밍에
    // 직접 "측정 시작"을 눌러야 캡처가 시작되도록 바꿨다 — 준비되기 전에 소리가 잡히는 걸 방지.
    @State private var isCapturing = false
    // "측정 시작"을 눌러도 반응이 statusText 한 줄에 묻혀서 왜 안 되는지 알기 어려웠다 —
    // 마이크 권한이 꺼진 상태는 버튼을 누르기도 전에(onAppear에서) 미리 감지해서 전용 UI로 보여준다.
    @State private var micPermissionDenied = false

    @State private var statusText = "마이크 대기 중..."
    @State private var keyText = ""
    @State private var harmonyText = ""
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

    // 멜로디 전체의 화음 라인(3도 또는 5도)을 이어서 들려주는 재생 상태 — "도미솔을 부르면
    // 그 3도/5도를 처음부터 끝까지 이어서 들려준다"는 요청에 대응한다.
    @State private var playingMelodyLineInterval: ChordGenerator.Interval?
    @State private var melodyLineTask: Task<Void, Never>?

    // "내 목소리로 화음 만들기" — 합성음(TonePlayer) 대신 사용자 목소리를 그대로 3도/5도 위로
    // 옮겨서 재생한다. 버튼을 누른 "이후"에 새로 녹음하는 방식이었을 땐, 이미 노래를 마치고
    // 조용해진 상태에서 버튼을 누르면 그 녹음 구간이 무음이라 아무 소리도 안 나는 문제가 있었다.
    // 그래서 방금까지 부른 소리를 항상 롤링 버퍼에 담아두고, 버튼을 누르면 그 자리에서 바로
    // 그걸 피치 시프트해서 재생하는 방식으로 바꿨다.
    @State private var recentVoiceBuffer: [Float] = []
    @State private var recentVoiceSampleRate: Double = 44100
    // 단음 모드는 음 하나만 담으면 되니 짧게(1.5초) 유지한다. 멜로디 모드는 "도미솔"처럼
    // 여러 음을 이어 부른 걸 전부 화음으로 옮겨 듣고 싶어하므로, 노래 한 프레이즈가
    // 통째로 잘리지 않도록 훨씬 넉넉하게(30초) 잡는다 — 무제한으로 두면 캡처를 오래
    // 켜둔 채 계속 두는 경우 버퍼가 한없이 커질 수 있어(24절 이후로는 마이크가 켜져
    // 있는 한 항상 raw 오디오가 쌓이므로) 상한선은 남겨둔다.
    private var recentVoiceBufferMaxDuration: Double {
        sessionMode == .melody ? 30.0 : 1.5
    }
    private let voiceClipPlayer = VoiceClipPlayer()
    // 목소리 화음 재생 시작/끝에 적용할 페이드 길이 — 롤링 버퍼에서 잘라낸 구간은 원본
    // 파형의 임의 지점에서 시작/끝나서, 그대로 재생하면 클릭음이 날 수 있다(AudioGain 참고).
    private let voiceClipFadeDuration: Double = 0.015

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
        // 안 들어가면 자동으로 세로 배치로 바뀌게 했다(실기기 대신 시뮬레이터의 접근성 최대 글자
        // 크기 설정으로 실제 깨지는 걸 확인하고 고쳤다).
        ViewThatFits {
            HStack { picker; listenButton }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) { picker; listenButton }
        }
    }

    /// 마이크 권한이 꺼져 있을 때 캡처 카드 자리에 보여주는 전용 상태 — "왜 안 되는지" 설명하고
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
                        Picker("모드", selection: $sessionMode) {
                            ForEach(SessionMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: sessionMode) { _, _ in resetSession() } // 모드가 바뀌면 상태가 섞이지 않게 항상 리셋

                    // 캡처: 항상 보이는 유일한 카드 — 여기서부터 흐름이 시작된다.
                    // 정보를 한 덩어리로 몰아넣지 않고 세 그룹(측정 버튼 -> 파형+판독값 ->
                    // 시작음 컨트롤)으로 나누고, 그룹 사이엔 카드 안 다른 요소보다 넓은 간격을 준다.
                    HarmonyCard("실시간 피치", systemImage: "waveform") {
                        if micPermissionDenied {
                            micPermissionDeniedContent
                        } else if sessionMode == .quickRecord {
                            QuickRecordView(
                                phase: quickRecordPhase,
                                elapsed: Double(quickRecordBuffer.count) / quickRecordSampleRate,
                                maxDuration: quickRecordMaxDuration,
                                waveformSamples: quickRecordBuffer,
                                onStart: startQuickRecording,
                                onStop: stopQuickRecording,
                                onReset: resetSession
                            )
                        } else {
                            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                                Button(action: toggleCapture) {
                                    Label(isCapturing ? "측정 중지" : "측정 시작", systemImage: isCapturing ? "stop.fill" : "mic.fill")
                                }
                                .buttonStyle(.borderedProminent)

                                if isCapturing {
                                    // 지금 마이크가 실제로 소리를 듣고 있다는 걸 텍스트보다 훨씬
                                    // 직관적으로 보여준다 — "녹음 중"이라는 상태 자체를 시각화.
                                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                        WaveformView(samples: recentVoiceBuffer)
                                            .frame(height: 88)
                                            .padding(.horizontal, Theme.Spacing.sm)
                                            .frame(maxWidth: .infinity)
                                            .background(
                                                Theme.tint.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4, style: .continuous)
                                            )

                                        Text(statusText)
                                            .font(.system(.title2, design: .monospaced))
                                    }
                                } else {
                                    Text(statusText)
                                        .font(.system(.title2, design: .monospaced))
                                }

                                Text(isCapturing ? singleNoteStatusHint : "측정 시작을 눌러야 마이크가 켜집니다")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)

                                // 노래를 시작하기 전 여기서 바로 기준음을 듣고 첫 음을 잡을 수 있게.
                                startingNoteControls
                            }
                        }
                    }
                    .id("captureCard")

                    // 조성+화음: 첫 음이 잡히기 전엔 아예 렌더링하지 않는다(점진적 공개) —
                    // "아직 판별되지 않음" 같은 빈 상태를 계속 보여주는 대신, 관련 데이터가
                    // 생긴 뒤에만 화면에 등장하게 한다.
                    if hasCapturedNote {
                        HarmonyCard("조성과 화음", systemImage: "music.note.list") {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                Text(keyText)
                                    .font(Theme.Typography.subheadline)

                                if sessionMode == .melody || sessionMode == .quickRecord {
                                    if melodySteps.isEmpty {
                                        Text("아직 잡은 음 없음")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(Array(melodySteps.enumerated()), id: \.element.id) { index, step in
                                                MelodyStepRow(
                                                    step: step,
                                                    onCorrect: { pitchClass in correctMelodyStep(at: index, toPitchClass: pitchClass) },
                                                    onScoreThird: { startScoringMelodyStep(at: index, interval: .third) },
                                                    onScoreFifth: { startScoringMelodyStep(at: index, interval: .fifth) }
                                                )
                                            }
                                        }
                                        Text("음을 눌러서 고치거나, 3도/5도로 그 스텝을 바로 채점할 수 있어요")
                                            .font(Theme.Typography.caption2)
                                            .foregroundStyle(.secondary)

                                        // 도-미-솔을 부르면 그 3도(또는 5도) 라인을 처음부터 끝까지
                                        // 이어서 들려준다 — 멜로디 전체를 화음으로 들어보는 것.
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
                                    }
                                } else {
                                    Text(harmonyText.isEmpty ? "아직 제안 없음" : harmonyText)
                                        .foregroundStyle(harmonyText.isEmpty ? .secondary : .primary)
                                }

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

                    // 내 목소리로 화음: 화음이 나오기 전엔 안 보인다(할 게 없으므로). 화음이
                    // 생긴 뒤엔, 목소리 버퍼가 아직 덜 찼어도 카드 자체는 계속 보이게 둔다 —
                    // "확보된 목소리: N초" 캡션이 "조금만 더 부르면 된다"는 유용한 피드백이라서다.
                    if melodySession.suggestedHarmony != nil {
                        HarmonyCard("내 목소리로 화음", systemImage: "music.mic", iconColor: Theme.voiceAccent) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                // 버튼보다 먼저 설명을 둬서, 뭘 누르기 전에 "이게 뭘 하는 버튼인지"부터
                                // 읽히게 한다 — 예전엔 버튼 아래 작은 캡션이라 자칫 못 보고 지나치기 쉬웠다.
                                Text(String(format: "방금까지 부른 음을 그대로 3도/5도로 옮겨서 들려줘요 (확보된 목소리: %.1f초)",
                                            Double(recentVoiceBuffer.count) / recentVoiceSampleRate))
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.secondary)

                                // ViewThatFits: 버튼 3개가 한 줄에 안 들어갈 만큼 글자가 커지면
                                // 세로 배치로 자동 전환된다(가로 배치가 압축되며 깨지는 것 방지).
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
                                // 예전엔 조건 여러 개를 한꺼번에 disabled에 걸어놔서, 어떤 조건 때문에
                                // 막혔는지 사용자가 알 수 없이 "눌러도 반응 없음"으로만 보였다.
                                // 최소한(측정 꺼짐/재생 중)만 막고, 나머지는 눌렀을 때 이유를 메시지로 알려준다.
                                .disabled(!isCapturing || isPlaybackBusy)
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

                        Button(role: .destructive, action: resetSession) {
                            Label("다시 시작", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
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
            // 버튼을 눌러보기 전에 미리 알려준다 — 이전에 거부했다면 "측정 시작"을 눌러도
            // 반응이 statusText 한 줄에 묻혀서 왜 안 되는지 알기 어려웠다.
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

    private var singleNoteStatusHint: String {
        if activeScoringInterval != nil {
            return "🎯 채점 중 — 목표음을 따라 부르는 동안엔 새 멜로디 음을 잡지 않습니다"
        }
        switch sessionMode {
        case .quickRecord:
            return "" // 이 텍스트는 quickRecord 모드의 캡처 카드(QuickRecordView)에서는 아예 쓰이지 않는다
        case .single:
            return hasCapturedNote ? "🔒 음 고정됨 — 다시 시작을 눌러야 새로 잡습니다" : "음을 안정적으로 내면 자동으로 잡습니다"
        case .melody:
            return "음을 계속 이어 부르면 음마다 화음이 순서대로 쌓입니다"
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

    /// "측정 시작/중지" 버튼에 연결된다. AudioCapture는 stop() 이후 다시 start()해도
    /// 안전하게 재사용 가능하도록 만들어져 있어서(탭을 새로 걸고 엔진을 다시 돌림),
    /// 버튼을 여러 번 눌러도 문제없다.
    private func toggleCapture() {
        if isCapturing {
            // 측정 자체를 끄면 채점도 더 이상 진행할 수 없으므로, 진행 중이던 채점이 있다면
            // 먼저 기록으로 저장하고 정리한다 — 안 그러면 "3도 채점"이 켜진 채로 마이크만 꺼져서
            // 다음에 뭘 눌러도 반응이 없는 것처럼 보이는 상태가 된다.
            if let active = activeScoringInterval {
                finalizeCurrentAttempt(interval: active)
                activeScoringInterval = nil
            }
            audioCapture.stop()
            isCapturing = false
            statusText = "측정 중지됨"
            return
        }

        beginCapturingIfNeeded()
    }

    /// 측정이 꺼져 있으면 켠다. 이미 켜져 있으면 아무 것도 하지 않는다(중복 start 방지).
    /// "채점하기" 버튼도 이걸 호출해서, 사용자가 미리 "측정 시작"을 눌러두지 않았어도
    /// 채점 버튼 하나로 바로 측정+채점이 시작되게 한다.
    ///
    /// 마이크 권한을 먼저 확인한다 — 거부된 상태에서 그냥 start()를 호출하면 실패 이유가
    /// statusText 한 줄짜리 에러 메시지로만 나타나서 눈에 잘 안 띄었다. 여기서 미리 걸러서
    /// 전용 UI(micPermissionDeniedContent)로 보여준다.
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

                // 빠른 녹음 중엔 이 프레임을 quickRecordBuffer에 쌓기만 하고 아래(단음/멜로디용)
                // 실시간 확정 로직은 전혀 타지 않는다 — 빠른 녹음은 "다 부른 뒤에 한 번에" 분석하는
                // 별도 배치 경로라서 실시간 확정 로직과 섞이면 안 된다. 녹음이 끝난 뒤 "따라 부르기
                // 채점"으로 마이크가 다시 켜질 때는 quickRecordPhase가 더 이상 .recording이 아니므로
                // 이 분기를 건너뛰고 곧장 맨 아래 채점 로직으로 간다.
                if sessionMode == .quickRecord && quickRecordPhase == .recording {
                    quickRecordBuffer.append(contentsOf: rawSamples)
                    quickRecordSampleRate = rawSampleRate
                    if Double(quickRecordBuffer.count) / rawSampleRate >= quickRecordMaxDuration {
                        stopQuickRecording()
                    }
                    return
                }

                // "내 목소리로 화음 만들기"용 롤링 버퍼 — result(피치 검출 성공 여부)와 무관하게
                // 매 프레임 원본을 그대로 담는다. 예전엔 result가 있을 때만(=VAD+YIN이 성공한
                // 프레임만) 담아서, 음과 음 사이 숨소리/발음 전환 같은 짧은 무음 구간이 통째로
                // 빠져 여러 음이 이어붙을 때 뚝뚝 끊기듯 들리고, 아주 짧거나 조용한 음은 그
                // 프레임 전체가 걸러져 화음에서 통째로 빠지는 문제(예: 6음인데 5음만 들림)가
                // 있었다. 원본을 그대로 이어붙이면 실제 부른 타이밍/이음매가 그대로 보존된다.
                // quickRecord 모드에서는(분석 결과가 이미 recentVoiceBuffer를 전체 녹음으로 채워둔
                // 상태라) 여기서 롤링 버퍼로 덮어쓰지 않는다.
                if sessionMode != .quickRecord {
                    recentVoiceBuffer.append(contentsOf: rawSamples)
                    recentVoiceSampleRate = rawSampleRate
                    let maxSamples = Int(recentVoiceBufferMaxDuration * rawSampleRate)
                    if recentVoiceBuffer.count > maxSamples {
                        recentVoiceBuffer.removeFirst(recentVoiceBuffer.count - maxSamples)
                    }
                }

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
                // 채점 중(activeScoringInterval != nil)에도 멜로디 모드에서 캡처를 멈춘다 —
                // 안 그러면 목표음을 따라 부르는 소리 자체가 "새 멜로디 음"으로 잡혀서 조성/화음이
                // 계속 바뀌는 문제가 있었다.
                // quickRecord 모드에서 채점 화면으로 재진입했을 때는(마이크가 다시 켜지지만) 이
                // 실시간 음 확정 로직(단음/멜로디 전용)을 건너뛴다 — melodySession/melodySteps는
                // 이미 RecordingAnalyzer 결과로 채워져 있고, 지금 마이크가 켜진 목적은 아래 채점뿐이다.
                let shouldEvaluateCapture = sessionMode != .quickRecord
                    && activeScoringInterval == nil
                    && (sessionMode == .melody || !hasCapturedNote)

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

                if let interval = activeScoringInterval, let target = lockedScoringTargets[interval] {
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
            }
            isCapturing = true
            statusText = "..."
        } catch {
            statusText = "마이크 시작 실패: \(error.localizedDescription)"
        }
    }

    /// "녹음 시작" 버튼 — 단음/멜로디의 "측정 시작"과 달리 켜자마자 확정 로직을 돌리지 않고,
    /// 사용자가 "녹음 그만"을 누를 때까지 quickRecordBuffer에 원본을 그대로 모으기만 한다.
    /// 마이크 자체는 beginCapturingIfNeeded()가 켜는 같은 audioCapture를 그대로 재사용한다 —
    /// 그 안의 클로저가 sessionMode/quickRecordPhase를 보고 알아서 이 모드용 분기를 탄다.
    private func startQuickRecording() {
        quickRecordBuffer = []
        quickRecordPhase = .recording
        beginCapturingIfNeeded()
    }

    /// "녹음 그만" 버튼(또는 30초 상한 도달 시 자동 호출) — 마이크를 멈추고, 지금까지 모은 녹음
    /// 전체를 RecordingAnalyzer로 한 번에 분석한다. YIN을 윈도우마다 돌리는 무거운 계산이라
    /// (recordAndHarmonizeVoice와 같은 이유로) Task로 감싸서 메인 스레드가 멈추지 않게 한다.
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

    /// RecordingAnalyzer의 배치 분석 결과를, 기존 단음/멜로디 UI가 그대로 소비할 수 있는 상태로 반영한다.
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
            let harmonyNames = ChordGenerator.generateHarmony(melodyFrequency: frequency, key: key).map { harmony in
                harmony
                    .map { NoteNameConverter.convert(frequency: $0.frequency)?.noteName ?? "?" }
                    .joined(separator: ", ")
            }
            return MelodyStep(noteName: noteName, midiNote: note.midiNote, harmonyNames: harmonyNames, onsetTime: note.onsetTime, duration: note.duration)
        }

        // "내 목소리로 화음"/채점 카드가 그대로 재사용하는 recentVoiceBuffer를 녹음 전체로 채운다 —
        // 이후 3도/5도/전체 화음 버튼을 누르면(mode != .single이라 트리밍 없이) 이 전체 녹음이 피치시프트된다.
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

    /// 멜로디 각 스텝을 현재(최신) 조성 기준으로 다시 계산해서, interval(3도 또는 5도) 라인 전체를
    /// 순서대로 반환한다. 저장된 harmonyNames 문자열 대신 매번 새로 계산하는 이유는, 사용자가 중간에
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

    /// "내 목소리로 화음 만들기" — 방금까지 부른 소리(recentVoiceBuffer)를 3도/5도 위로
    /// 피치 시프트해서, 합성음이 아니라 사용자 자신의 목소리 톤으로 화음을 즉시 들려준다.
    private func recordAndHarmonizeVoice(interval: ChordGenerator.Interval) {
        // 버튼을 눌렀는데 아무 것도 안 바뀌는 것처럼 보이는 문제를 막기 위해, 막힌 이유를
        // 항상 statusText로 알려준다 — 조용히 return만 하면 "눌러도 반응 없음"으로 보인다.
        guard isCapturing else {
            statusText = "먼저 측정을 시작하세요"
            return
        }
        guard !isPlaybackBusy else {
            statusText = "다른 소리가 재생 중이에요 — 끝난 뒤 다시 눌러주세요"
            return
        }
        guard melodySession.suggestedHarmony != nil else {
            statusText = "아직 화음이 없어요 — 먼저 음을 안정적으로 불러주세요"
            return
        }
        guard let ratio = pitchRatio(toInterval: interval) else {
            statusText = "목표음을 계산하지 못했어요"
            return
        }
        guard !recentVoiceBuffer.isEmpty else {
            statusText = "아직 잡힌 목소리가 없어요 — 먼저 노래를 불러주세요"
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
        let mode = sessionMode
        statusText = "화음 만드는 중…"

        Task {
            // 단음 모드에서만 트리밍한다 — 롤링 버퍼가 음이 바뀌어도 무조건 최근 시간을
            // 담고 있어서, 지금 기준 음과 상관없는 예전 음/숨소리가 앞쪽에 섞여있을 수 있고
            // 그걸 그대로 옮기면 음정이 왔다갔다하는 것처럼 들린다. 멜로디 모드는 반대로
            // "도미솔"처럼 여러 음을 이어 부른 전체를 그대로 옮겨 듣고 싶어하는 경우라,
            // 여기서 마지막 음 기준으로 트리밍해버리면 뒷부분(마지막 음)만 남고 나머지가
            // 잘려나가는 문제가 생긴다 — 그래서 멜로디 모드는 버퍼 전체를 그대로 쓴다.
            let stableSegment: [Float]
            if mode == .single, let rootFrequency {
                stableSegment = VoiceSegmentTrimmer.trimToStableSegment(samples: recorded, sampleRate: rate, targetFrequency: rootFrequency)
            } else {
                stableSegment = recorded
            }
            let shifted = PitchShifter.shift(samples: stableSegment, pitchRatio: ratio, sampleRate: rate, expectedFrequency: rootFrequency)
            // 마이크로 녹음한 원본은 보통 피크가 한참 낮게 들어와서(합성음보다 훨씬 작게 들림),
            // 재생 전에 거의 꽉 차는 수준(0.95)까지 디지털 게인을 올려서 체감 음량을 키운다.
            let normalized = AudioGain.normalize(shifted)
            // 트리밍/롤링 버퍼는 원본 파형의 임의 지점에서 잘려 있어서, 그대로 재생하면 시작/끝에서
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
        guard isCapturing else {
            statusText = "먼저 측정을 시작하세요"
            return
        }
        guard !isPlaybackBusy else {
            statusText = "다른 소리가 재생 중이에요 — 끝난 뒤 다시 눌러주세요"
            return
        }
        guard melodySession.suggestedHarmony != nil else {
            statusText = "아직 화음이 없어요 — 먼저 음을 안정적으로 불러주세요"
            return
        }
        guard let thirdRatio = pitchRatio(toInterval: .third),
              let fifthRatio = pitchRatio(toInterval: .fifth) else {
            statusText = "목표음을 계산하지 못했어요"
            return
        }
        guard !recentVoiceBuffer.isEmpty else {
            statusText = "아직 잡힌 목소리가 없어요 — 먼저 노래를 불러주세요"
            return
        }

        let recorded = recentVoiceBuffer
        let rate = recentVoiceSampleRate
        let rootFrequency = melodySession.lastNote?.frequency
        let mode = sessionMode
        statusText = "전체 화음 만드는 중…"

        Task {
            // 단음 모드에서만 트리밍한다(위 recordAndHarmonizeVoice와 같은 이유) — 멜로디
            // 모드는 부른 멜로디 전체를 그대로 옮겨야 하므로 자르지 않는다. 세 트랙
            // (원음+3도+5도)이 전부 같은 구간을 기준으로 만들어져야 화음이 흔들리지 않는다.
            let stableSegment: [Float]
            if mode == .single, let rootFrequency {
                stableSegment = VoiceSegmentTrimmer.trimToStableSegment(samples: recorded, sampleRate: rate, targetFrequency: rootFrequency)
            } else {
                stableSegment = recorded
            }

            // 원음(비율 1.0, 시프트 없이 그대로) + 3도 + 5도로 각각 옮긴 목소리를 만든다.
            let third = PitchShifter.shift(samples: stableSegment, pitchRatio: thirdRatio, sampleRate: rate, expectedFrequency: rootFrequency)
            let fifth = PitchShifter.shift(samples: stableSegment, pitchRatio: fifthRatio, sampleRate: rate, expectedFrequency: rootFrequency)
            // 세 트랙을 섞으면 각자보다 커지므로, mixAndNormalize가 합친 뒤 다시 피크 기준으로
            // 정규화해서 서로 다른 음 개수(1개 vs 3개)에 상관없이 항상 비슷한 체감 음량이 되게 한다.
            let mixed = AudioGain.mixAndNormalize([stableSegment, third, fifth])
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

        // "채점하기"를 눌렀는데 마이크가 꺼져 있으면 자동으로 켜준다 — 측정 시작을 따로
        // 누르지 않아도 채점 버튼 하나로 바로 측정+채점이 시작되게.
        beginCapturingIfNeeded()
    }

    /// 멜로디 모드에서 특정 스텝(마지막 음이 아니어도 됨)을 골라 그 자리에서 바로 채점을 시작한다.
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
        pendingPitchClass = nil
        pendingStreak = 0
        lastCapturedPitchClass = nil
        melodySteps = []
        keyText = ""
        harmonyText = ""
        statusText = "..."
        quickRecordPhase = .idle
        quickRecordBuffer = []
    }
}
