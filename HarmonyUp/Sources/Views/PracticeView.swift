import SwiftUI
import SwiftData
import AVFAudio
import UIKit

/// "내 목소리로 화음" 재생에서 켜고 끌 수 있는 성부 — `ChordGenerator.Interval`(베이스/3도/5도)
/// 3개에 리드 멜로디(원음)를 더한 4가지. 멜로디는 화음 성부가 아니라서 `Interval`에는 없지만,
/// 재생 시 뮤트 대상으로는 다른 성부와 동등하게 다뤄야 해서 별도 enum으로 감쌌다.
enum PlaybackVoice: CaseIterable, Hashable {
    case melody
    case bass
    case third
    case fifth

    var koreanLabel: String {
        switch self {
        case .melody: return "멜로디"
        case .bass: return ChordGenerator.Interval.bass.koreanLabel
        case .third: return ChordGenerator.Interval.third.koreanLabel
        case .fifth: return ChordGenerator.Interval.fifth.koreanLabel
        }
    }

    /// 멜로디(원음)는 화음 성부가 아니라서 대응하는 `Interval`이 없다.
    var interval: ChordGenerator.Interval? {
        switch self {
        case .melody: return nil
        case .bass: return .bass
        case .third: return .third
        case .fifth: return .fifth
        }
    }
}

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
    // 3도/5도를 각각 독립적으로 채점한다 — 하나 채점하다 다른 쪽으로 넘어가도
    // 이전 것의 최근 결과(latestScores)는 화면에 그대로 남아있는다. 실제로 마이크가
    // 매 순간 채점하는 대상은 하나(activeScoringInterval)뿐이지만, 그 결과와 사람이 부르는
    // 동안 쌓인 샘플은 interval별로 따로 보관해서 서로 덮어쓰지 않게 한다.
    @State private var activeScoringInterval: ChordGenerator.Interval?
    @State private var lockedScoringTargets: [ChordGenerator.Interval: ChordGenerator.HarmonyNote] = [:]
    @State private var latestScores: [ChordGenerator.Interval: PitchScorer.Score] = [:]
    @State private var scoreSampleBuffers: [ChordGenerator.Interval: [PitchScorer.Score]] = [:]

    // 첫 녹음 분석이 끝났는지 — 점진적 공개("내 목소리로 화음"/"따라 부르기 채점" 카드 등장
    // 여부) 판단에 쓴다. melodySteps 자체(음이름+옥타브+화음+시작시각/길이)는 지금은 화면에
    // 직접 표시하지 않지만(조성/화음 요약 카드는 제거했다 — 지금 단계에선 필요 없다는 판단),
    // 다음 단계인 악보 렌더링에 그대로 필요한 데이터라 계속 계산해서 들고 있는다.
    @State private var hasCapturedNote = false
    @State private var melodySteps: [MelodyStep] = []

    // "내 목소리로 화음 만들기" — 합성음(TonePlayer) 대신 사용자 목소리를 그대로 베이스/3도/5도로
    // 옮겨서 재생한다. 빠른 녹음이 끝나면 녹음 전체가 그대로 여기 채워진다(applyQuickRecordResult).
    @State private var recentVoiceBuffer: [Float] = []
    @State private var recentVoiceSampleRate: Double = 44100
    // "전체 화음"/"화음만 듣기"로 나뉘어 있던 두 버튼을, 성부별로 켜고 끌 수 있는 토글 하나로
    // 일반화했다(로드맵 Phase 4, docs/CONCEPTS.md 53절) — 리드 멜로디도 다른 성부와 동등하게
    // 뮤트 대상이 된다. 기본값은 전부 켜짐(예전 "전체 화음" 버튼과 동일한 동작).
    @State private var mutedVoices: Set<PlaybackVoice> = []
    private let voiceClipPlayer = VoiceClipPlayer()
    // 목소리 화음 재생 시작/끝에 적용할 페이드 길이 — 녹음 구간은 원본 파형의 임의 지점에서
    // 시작/끝나서, 그대로 재생하면 클릭음이 날 수 있다(AudioGain 참고).
    private let voiceClipFadeDuration: Double = 0.015

    private let audioCapture = AudioCapture()
    private let melodySession = MelodySession()
    private let pitchSmoother = PitchSmoother()

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

    // 재생 중(내 목소리 화음)엔 마이크를 완전히 무시한다 — 스피커 소리가 되먹임되는 피드백
    // 루프 방지. isPlayingVoiceClip이 빠져 있던 게 26절 버그의 원인이었다.
    private var isPlaybackBusy: Bool {
        isPlayingVoiceClip
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

                        // 악보(오선보) — 첫 녹음 분석이 끝나기 전엔 보여줄 게 없다.
                        if hasCapturedNote {
                            HarmonyCard("악보", systemImage: "pianokeys") {
                                SheetMusicView(steps: melodySteps, mutedVoices: $mutedVoices)
                            }
                            .id("sheetMusicCard")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // 내 목소리로 화음: 화음이 나오기 전엔 안 보인다(할 게 없으므로).
                        if melodySession.suggestedHarmony != nil {
                            HarmonyCard("내 목소리로 화음", systemImage: "music.mic", iconColor: Theme.voiceAccent) {
                                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                    // 버튼보다 먼저 설명을 둬서, 뭘 누르기 전에 "이게 뭘 하는 버튼인지"부터
                                    // 읽히게 한다.
                                    Text(String(format: "방금 녹음한 노래를 그대로 베이스/3도/5도로 옮겨서 들려줘요 (확보된 목소리: %.1f초)",
                                                Double(recentVoiceBuffer.count) / recentVoiceSampleRate))
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(.secondary)

                                    // 성부별 뮤트 토글 — 눌러서 재생에 포함/제외할 성부를 자유롭게 고른다.
                                    // "내 목소리로 베이스/3도/5도"를 각각 따로 미리듣는 버튼은 이 토글로
                                    // 성부 하나만 켜고 재생하면 결과가 같아서(오히려 pan까지 적용돼 더
                                    // 일관됨) 따로 두지 않고 하나로 합쳤다 — 버튼 수를 줄여 카드를 더
                                    // 단순하게 다듬았다.
                                    ViewThatFits {
                                        HStack {
                                            ForEach(PlaybackVoice.allCases, id: \.self) { voice in
                                                voiceToggle(voice)
                                            }
                                        }
                                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                            ForEach(PlaybackVoice.allCases, id: \.self) { voice in
                                                voiceToggle(voice)
                                            }
                                        }
                                    }

                                    playEnabledVoicesButton
                                        .buttonStyle(.borderedProminent)
                                        .frame(maxWidth: .infinity)
                                        // "지금 쓸 수 있는 녹음이 있는지"만 본다 — isCapturing(마이크가
                                        // 지금 열려 있는지)로 막으면, 녹음을 다 마친 뒤(=isCapturing이
                                        // 이미 false) 정작 이 버튼을 못 누르는 문제가 있었다(실제로 겪은 버그).
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
                                    scoringPanel(for: .bass)
                                    Divider()
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
            audioCapture.stop()
            voiceClipPlayer.stop()
            isPlayingVoiceClip = false
        }
    }


    /// 성부 하나를 켜고 끄는 토글 칩 — 눌린 상태(재생에 포함)면 채워진 스타일, 꺼진 상태(뮤트)면
    /// 테두리만 있는 스타일로 구분한다. 전부 꺼진 채로 재생 버튼을 누르면 안내 메시지만 뜨고
    /// 아무 소리도 안 나므로(guard, 아래 recordAndHarmonizeFullChordWithVoice), 최소 하나는
    /// 남겨야 한다는 제약을 UI에서 강제로 막지는 않았다 — 자유롭게 다 꺼봤다가 이유를 읽고
    /// 다시 켜는 편이, 어떤 조합이 막혀있는지 미리 계산해서 버튼을 비활성화하는 것보다 단순하다.
    private func voiceToggle(_ voice: PlaybackVoice) -> some View {
        let isMuted = mutedVoices.contains(voice)
        return Button {
            if isMuted {
                mutedVoices.remove(voice)
            } else {
                mutedVoices.insert(voice)
            }
        } label: {
            Label(voice.koreanLabel, systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        }
        .buttonStyle(.bordered)
        .tint(isMuted ? .secondary : Theme.tint)
    }

    /// 켜져 있는 성부만 골라 동시에 재생한다 — 예전엔 "전체 화음"(전부 켜짐 고정)과 "화음만
    /// 듣기"(멜로디만 고정으로 꺼짐) 두 버튼으로 나뉘어 있던 걸, 토글로 자유롭게 조합할 수 있게
    /// 일반화했다(로드맵 Phase 4, docs/CONCEPTS.md 53절).
    private var playEnabledVoicesButton: some View {
        Button {
            recordAndHarmonizeFullChordWithVoice()
        } label: {
            Label("재생", systemImage: "play.fill")
        }
    }

    /// 성부(베이스/3도/5도) 하나에 대한 채점 패널 — 목표음, 바늘 미터, 시작/중지 버튼을 묶어서 보여준다.
    /// 세 패널이 서로 독립적이라 latestScores[interval]만 각자 참조하고, 다른 쪽 상태에 영향받지 않는다.
    @ViewBuilder
    private func scoringPanel(for interval: ChordGenerator.Interval) -> some View {
        let label = interval.koreanLabel
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

        guard let key = melodySession.detectedKey else {
            quickRecordPhase = .error("조성을 판별하지 못했어요 — 조금 더 길게 불러서 다시 녹음해주세요")
            return
        }
        // 2단계: 화면에 보여줄 스텝별 화음은, 녹음 전체를 다 보고 확정한 "최종" 조성 기준으로
        // 한 번에 다시 계산한다 — 실시간 캡처처럼
        // "그때까지 들은 것만으로 추측한 조성"을 스텝마다 다르게 쓰면, 이미 다 끝난 녹음을 배치로
        // 분석하는 이 경로에서는 앞부분 스텝의 화음이 뒤늦게 밝혀진 진짜 조성과 어긋나 보일 수 있다.
        // ChordGenerator.harmonizeSequence는 Viterbi로 노트 시퀀스 전체의 문맥을 보고 코드
        // 진행을 고르므로, 노트별로 따로따로가 아니라 한 번에 통째로 넘긴다(docs/CONCEPTS.md 51절).
        let harmonySequence = ChordGenerator.harmonizeSequence(
            melodyNotes: analyzed.notes.map { ($0.midiNote, $0.duration) },
            key: key
        )
        melodySteps = analyzed.notes.enumerated().map { index, note in
            let frequency = NoteNameConverter.frequency(forMIDINote: note.midiNote)
            let noteName = NoteNameConverter.convert(frequency: frequency)?.noteName ?? "?"
            let harmony = harmonySequence[index]
            return MelodyStep(
                noteName: noteName,
                midiNote: note.midiNote,
                harmonyVoices: MelodyStep.harmonyVoices(from: harmony),
                harmony: harmony,
                onsetTime: note.onsetTime,
                duration: note.duration
            )
        }

        // "내 목소리로 화음"/채점 카드가 그대로 재사용하는 recentVoiceBuffer를 녹음 전체로 채운다 —
        // 이후 3도/5도/전체 화음 버튼을 누르면 이 전체 녹음이 그대로 피치시프트된다.
        recentVoiceBuffer = analyzed.voiceSamples
        recentVoiceSampleRate = analyzed.sampleRate

        hasCapturedNote = true
        quickRecordPhase = .result(noteCount: analyzed.notes.count)
    }

    /// 마지막으로 잡은 음을 기준으로, 목표 interval(3도/5도) 위 주파수까지의 배율(pitchRatio)을 구한다.
    private func pitchRatio(toInterval interval: ChordGenerator.Interval) -> Double? {
        guard let lastFrequency = melodySession.lastNote?.frequency,
              let harmony = melodySession.suggestedHarmony,
              let target = harmony.first(where: { $0.interval == interval }) else { return nil }
        return target.frequency / lastFrequency
    }

    /// "내 목소리로 화음 만들기" — 방금 녹음한 소리(recentVoiceBuffer)를 `mutedVoices`에 안
    /// 들어있는(=켜진) 성부만 골라 베이스/3도/5도(+멜로디)로 피치 시프트해서 한꺼번에 동시
    /// 재생한다. 예전엔 "전체 화음"(고정 4성부)/"화음만 듣기"(멜로디 고정 제외)/"베이스·3도·
    /// 5도 각각 미리듣기" 여러 버튼으로 나뉘어 있던 걸, 토글 하나로 자유롭게 조합할 수 있게
    /// 일반화했다(로드맵 Phase 4, docs/CONCEPTS.md 53절).
    private func recordAndHarmonizeFullChordWithVoice() {
        guard !isPlaybackBusy else {
            statusText = "다른 소리가 재생 중이에요 — 끝난 뒤 다시 눌러주세요"
            return
        }
        guard melodySession.suggestedHarmony != nil else {
            statusText = "아직 화음이 없어요 — 먼저 녹음해주세요"
            return
        }
        guard let bassRatio = pitchRatio(toInterval: .bass),
              let thirdRatio = pitchRatio(toInterval: .third),
              let fifthRatio = pitchRatio(toInterval: .fifth) else {
            statusText = "목표음을 계산하지 못했어요"
            return
        }
        guard !recentVoiceBuffer.isEmpty else {
            statusText = "아직 녹음된 목소리가 없어요 — 먼저 녹음해주세요"
            return
        }
        // 전부 뮤트된 채로 누르면 재생할 게 없다 — 조용히 아무것도 안 하는 대신 이유를 알려준다
        // (버튼을 눌렀는데 반응이 없어 보이는 문제를 막기 위한, 이 파일 전반의 일관된 원칙).
        guard mutedVoices.count < PlaybackVoice.allCases.count else {
            statusText = "재생할 성부가 없어요 — 최소 하나는 켜주세요"
            return
        }

        let recorded = recentVoiceBuffer
        let rate = recentVoiceSampleRate
        let rootFrequency = melodySession.lastNote?.frequency
        let muted = mutedVoices
        statusText = "화음 만드는 중…"

        Task {
            // 예전엔 트랙들을 Swift 배열 단계에서 미리 하나로 합쳐서(AudioGain.mixAndNormalize)
            // 재생했는데, 그러면 성부가 전부 같은 위치(모노)에서만 나와서 서로 뭉개져 들렸다.
            // 이제 각 트랙을 자기 체감 음량으로만 맞추고(합치지 않음) VoiceClipPlayer.playTracks로
            // 넘겨서, 켜진 성부가 실제로 다른 좌우 위치에서 동시에 나오게 한다(docs/CONCEPTS.md 52절).
            let fadeCount = Int(rate * voiceClipFadeDuration)
            func prepare(_ samples: [Float]) -> [Float] {
                AudioGain.applyFadeInOut(AudioGain.normalizeLoudness(samples), fadeSampleCount: fadeCount)
            }

            var tracks: [(samples: [Float], pan: Float)] = []

            if !muted.contains(.melody) {
                tracks.append((prepare(recorded), 0.0)) // 리드 멜로디는 중앙
            }
            // 베이스(한 옥타브 아래, 비율 < 1) + 3도 + 5도로 각각 옮긴 목소리를 만든다.
            // PitchShifter.shift는 비율이 1보다 작아도(음을 낮출 때도) 그대로 동작하는
            // 양방향이라 베이스만 따로 다른 처리가 필요 없다. 꺼진 성부는 계산 자체를 건너뛴다
            // (WORLD 분석은 가볍지 않아서, 안 쓸 트랙까지 굳이 만들 필요 없음).
            for (voice, interval, ratio) in [(PlaybackVoice.bass, ChordGenerator.Interval.bass, bassRatio),
                                              (.third, .third, thirdRatio),
                                              (.fifth, .fifth, fifthRatio)] where !muted.contains(voice) {
                let shifted = PitchShifter.shift(samples: recorded, pitchRatio: ratio, sampleRate: rate, expectedFrequency: rootFrequency)
                // 성부마다 다른 지연/디튠으로 더블링해서 두께를 준다 — 멜로디(원음)는 그대로 둔다.
                // 이미 사용자 자신이 직접 부른 진짜 목소리라 "다른 사람이 한 번 더 부른" 효과가
                // 필요 없고, 오히려 원음이 흔들리면 리드로서의 기준점이 흐려진다.
                let doubled = VoiceDoubler.apply(to: shifted, sampleRate: rate, interval: interval)
                tracks.append((prepare(doubled), interval.pan))
            }

            do {
                isPlayingVoiceClip = true
                try voiceClipPlayer.playTracks(tracks, sampleRate: rate) {
                    isPlayingVoiceClip = false
                }
                statusText = "내 목소리로 만든 화음을 재생합니다"
            } catch {
                isPlayingVoiceClip = false
                statusText = "재생 실패: \(error.localizedDescription)"
            }
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

    /// 지금까지 쌓인 채점 샘플들을 하나의 요약(PracticeSummary.Aggregate)으로 압축해서
    /// SwiftData에 저장하고, 다음 시도를 위해 그 interval의 샘플 버퍼만 비운다.
    private func finalizeCurrentAttempt(interval: ChordGenerator.Interval) {
        defer { scoreSampleBuffers[interval] = [] }

        guard let target = lockedScoringTargets[interval],
              let samples = scoreSampleBuffers[interval],
              let aggregate = PracticeSummary.aggregate(scores: samples) else { return }

        let attempt = PracticeAttempt(
            date: Date(),
            intervalRawValue: interval.storageKey,
            targetNoteName: NoteNameConverter.convert(frequency: target.frequency)?.noteName ?? "?",
            sampleCount: aggregate.sampleCount,
            onPitchRatio: aggregate.onPitchRatio,
            averageAbsCentsOffset: aggregate.averageAbsCentsOffset
        )
        modelContext.insert(attempt)
    }

    private func resetSession() {
        if let active = activeScoringInterval {
            finalizeCurrentAttempt(interval: active) // 리셋 직전까지의 채점 시도도 버리지 않고 기록으로 남긴다
        }

        voiceClipPlayer.stop()
        isPlayingVoiceClip = false
        recentVoiceBuffer = []
        mutedVoices = []
        activeScoringInterval = nil
        lockedScoringTargets = [:]
        latestScores = [:]
        scoreSampleBuffers = [:]
        pitchSmoother.reset()
        melodySession.reset()
        hasCapturedNote = false
        melodySteps = []
        statusText = ""
        quickRecordPhase = .idle
        quickRecordBuffer = []
    }
}
