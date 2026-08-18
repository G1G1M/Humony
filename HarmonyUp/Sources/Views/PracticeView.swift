import SwiftUI
import SwiftData
import AVFAudio
import UIKit
import Combine

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
    // 아이패드(또는 가로모드 대화면 아이폰)에서 왼쪽=녹음/재생/채점, 오른쪽=악보(상시 큼) 두 열
    // 레이아웃으로 바꾸는 기준. 기기 종류(UIDevice.userInterfaceIdiom)가 아니라 실제 표시 폭으로
    // 판단하는 게 애플이 권장하는 적응형 방식이라, 아이패드 Split View로 좁아지면 자동으로 아이폰
    // 방식으로 폴백되고 반대로 대화면 아이폰 가로모드에서도 자연스럽게 두 열이 적용된다.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    // 빠른 녹음 전용 상태 — 녹음 전체를 모았다가 멈춘 뒤 한 번에 RecordingAnalyzer로 분석한다.
    @State private var quickRecordPhase: QuickRecordView.Phase = .idle
    @State private var quickRecordBuffer: [Float] = []
    @State private var quickRecordSampleRate: Double = 44100
    // WSOLA 피치시프트 비용(다중 음 화음 만들 때)과 결과 악보의 가로 스크롤 UX를 고려한 상한.
    private let quickRecordMaxDuration: Double = 30.0

    // 녹음 전 참고음(첫음) 골라 듣기 — 무반주로 노래를 시작할 때 음정을 잡기 위한 순수 참고용
    // 기능이다. 예전엔 "조성과 화음" 카드 안에 있었는데(54절에서 카드째 정리) 사용자가 다시
    // 요청해서 복원한다 — 이번엔 분석 파이프라인과 완전히 분리된 채로(melodySession 등은
    // 전혀 안 건드림), 녹음 시작 전에만 보이는 별도 컨트롤로 둔다.
    @State private var startingNoteMIDI: Int = 60 // C4, 항상 도로 시작하도록 고정(74절)
    @State private var isPlayingStartingNote = false
    private let startingNotePlayer = TonePlayer()
    // 녹음 중 마이크 헤일로 애니메이션용 실시간 음량(0~1로 정규화). VoiceActivityDetector와 같은
    // 방식(제곱평균제곱근)으로 매 프레임 계산해서 QuickRecordView에 넘긴다.
    @State private var recordingLevel: Float = 0
    // 정상적으로 노래할 때 나올 법한 RMS 상한 — 이걸로 나눠서 0~1로 정규화한다. 아이패드
    // 실기기에서 가까이 대고 불러도 최대 진폭(peak)이 0.01 안팎으로 실측됐다(stopQuickRecording
    // 참고, "노래 인식 안 됨" 진단 과정에서 추측 아닌 실측으로 확인됨) — RMS는 보통 peak보다
    // 낮으므로(사인파 기준 peak/√2, 실제 발성은 더 낮음) 그보다 한 자릿수 작게 잡았다. 기기별
    // 마이크 게인 차이가 있을 수 있어 여전히 시작점 — 헤일로가 너무 안 커지거나 바로 최대치로
    // 붙어버리면 이 값을 조정하면 된다.
    private let recordingLevelNormalization: Float = 0.006

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
    // 악보 카드가 뜬 시점엔 항상 true로 시작 — WKWebView 프로세스가 늦게 뜰 수 있어서(76절),
    // 첫 렌더가 끝날 때까지는 화면이 비어 보이는 대신 "만드는 중" 표시를 겹쳐 보여준다.
    // VexFlowScoreView.Coordinator가 renderScore 자바스크립트 호출이 끝나면 false로 되돌린다.
    @State private var isScoreRendering = true
    // 악보 카드는 다른 카드들과 나란히 있어서 고정 높이 안에 좁게 보인다 — 렌더링이 제대로
    // 되는지 크게 확인하고 싶을 때 이 상태로 전체화면 뷰(SheetMusicFullScreenView)를 띄운다.
    @State private var showingFullScreenScore = false

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
            .harmonyButtonStyle(prominent: true)
        }
    }

    // 재생 중(내 목소리 화음)엔 마이크를 완전히 무시한다 — 스피커 소리가 되먹임되는 피드백
    // 루프 방지. isPlayingVoiceClip이 빠져 있던 게 26절 버그의 원인이었다.
    private var isPlaybackBusy: Bool {
        isPlayingVoiceClip
    }
    @State private var isPlayingVoiceClip = false

    // 카라오케 재생헤드(Phase 7) — "내 목소리로 화음" 재생이 시작된 실제 시각을 기록해두고,
    // 50ms마다 경과 시간을 melodySteps의 onsetTime/duration(원본 녹음 기준 초)과 비교해서
    // 지금 재생 중인 스텝의 인덱스를 찾는다. 새 타이밍 계산이 필요 없는 이유: PitchShifter.shift는
    // 피치만 바꾸고 길이는 그대로라, 재생 경과 시간과 원본 녹음 타임라인이 그대로 일치한다.
    @State private var voiceClipPlaybackStartedAt: Date?
    @State private var activePlaybackStepIndex: Int?
    // 탭으로 다른 지점을 다시 눌렀을 때(seekPlayback), 이전 재생의 onFinished 콜백이
    // voiceClipPlayer.stop() 이후에도 뒤늦게 도착해 방금 시작한 새 재생 상태를 지워버리는 걸
    // 막는 세대 토큰 — 재생을 새로 시작할 때마다 증가시키고, 콜백에서 세대가 다르면 무시한다.
    @State private var playbackGeneration = 0
    // .autoconnect()로 뷰가 살아있는 동안 항상 흐르지만, updatePlaybackStepIndex()가
    // voiceClipPlaybackStartedAt이 nil이면 즉시 return하므로 재생 중이 아닐 땐 사실상 아무 일도
    // 안 한다 — 재생 시작/종료마다 타이머를 새로 만들고 해제하는 생명주기 관리보다 단순하다.
    private let playheadTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    // 재생헤드가 다음 스텝으로 넘어갈 때마다 미세한 진동을 줘서(Phase 8 Task 5), 화면을 안
    // 보고 듣기만 해도 박자를 손끝으로 느낄 수 있게 한다. 마디의 첫 박(다운비트)은 더 강하게,
    // 나머지(업비트)는 약하게 — RhythmQuantizer.measureBreaks가 이미 "마디마다 음이 몇 개인지"
    // 계산해주므로, 그 구간의 시작 인덱스만 모아두면 다운비트 판정이 된다. VexFlowScoreView가
    // 악보를 그릴 때 쓰는 것과 똑같은 계산이지만, 여기선 소리(햅틱) 쪽에서만 필요해서 따로
    // 가볍게 한 번 더 돌린다(melodySteps가 바뀔 때만, 재생 중 매 tick마다가 아님).
    @State private var downbeatStepIndices: Set<Int> = []
    private let downbeatHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let upbeatHaptic = UIImpactFeedbackGenerator(style: .light)

    // 화음이 나오는 순간(카드 2개가 한꺼번에 등장) 새로 나타난 카드로 자동 스크롤하기 위한 판정.
    // melodySession.suggestedHarmony(Optional 배열) 자체는 Equatable이 아니라서, onChange/애니메이션
    // 트리거로 쓰기 쉬운 단순 Bool로 한 번 감싼다.
    private var hasHarmony: Bool { melodySession.suggestedHarmony != nil }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .tint(Theme.tint)
        .onReceive(playheadTimer) { _ in
            updatePlaybackStepIndex()
        }
        .onChange(of: activePlaybackStepIndex) { _, newIndex in
            triggerStepHaptic(for: newIndex)
        }
        .onAppear {
            #if DEBUG
            print("[PracticeView] onAppear — hasCapturedNote=\(hasCapturedNote), isCapturing=\(isCapturing), quickRecordPhase=\(quickRecordPhase)")
            #endif
            micPermissionDenied = AVAudioApplication.shared.recordPermission == .denied
        }
        .onDisappear {
            #if DEBUG
            print("[PracticeView] onDisappear — hasCapturedNote=\(hasCapturedNote), isCapturing=\(isCapturing), quickRecordPhase=\(quickRecordPhase)")
            #endif
            // audioCapture.stop()만 부르고 isCapturing을 그대로 두면, 뷰를 나갔다 돌아와서
            // 다시 녹음을 시작할 때 beginCapturingIfNeeded()의 "이미 켜져 있으면 무시" 가드가
            // 실제로는 꺼진 엔진을 "아직 켜져 있다"고 착각해 마이크를 다시 안 켜는 버그가
            // 생길 수 있다 — 뷰를 벗어날 땐 항상 false로 확실히 되돌린다.
            audioCapture.stop()
            isCapturing = false
            voiceClipPlayer.stop()
            isPlayingVoiceClip = false
            voiceClipPlaybackStartedAt = nil
            activePlaybackStepIndex = nil
            startingNotePlayer.stop()
            isPlayingStartingNote = false
        }
        .fullScreenCover(isPresented: $showingFullScreenScore) {
            SheetMusicFullScreenView(steps: melodySteps, mutedVoices: $mutedVoices, detectedKeyName: melodySession.detectedKey?.name)
        }
    }

    private var compactLayout: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        captureHero(prominent: false)
                            .id("captureCard")

                        // 악보(VexFlow 오선보) — 첫 녹음 분석이 끝나기 전엔 보여줄 게 없다.
                        if hasCapturedNote {
                            sheetMusicPanel(fillAvailable: false)
                                .id("sheetMusicCard")
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }

                        // 내 목소리로 화음 + 채점: 화음이 나오기 전엔 안 보인다(할 게 없으므로).
                        if melodySession.suggestedHarmony != nil {
                            voiceHarmonyPanel
                                .id("voiceHarmonyCard")
                                .transition(.opacity.combined(with: .move(edge: .top)))

                            scoringCard
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
    }

    // MARK: - 아이패드(레귤러) 레이아웃 — 2단계 상태 구조
    //
    // 1단계(대기/녹음 중, hasCapturedNote == false): 화면 중앙에 대형 히어로 마이크 버튼+파형만
    // 보이는 1컬럼. 2단계(분석 완료 후): 왼쪽(녹음 상태 요약+재생+채점)/오른쪽(악보, 상시 큼)
    // 2컬럼 스플릿으로 전환. 상단 툴바에 "홈으로"(완전 리셋, 1컬럼 대기 화면으로)와 "다시
    // 녹음"(기존 좌측 맥락은 유지한 채 즉시 마이크 재가동, 우측 악보만 분석 완료 시 갱신)을 분리.

    private var regularLayout: some View {
        NavigationStack {
            Group {
                if hasCapturedNote {
                    regularSplitStage
                } else {
                    regularHeroStage
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("연습")
            .toolbar {
                if hasCapturedNote {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            resetSession()
                        } label: {
                            Label("홈으로", systemImage: "chevron.left")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            // 다시 녹음: 세션 컨텍스트(악보/믹서/채점 기록)는 그대로 두고 마이크만
                            // 즉시 재가동한다 — startQuickRecording()이 hasCapturedNote/melodySteps를
                            // 건드리지 않아서, 새 분석이 끝나야(applyQuickRecordResult) 우측 악보가
                            // 그때 가서 자연스럽게 갱신된다("홈으로"의 완전 리셋과 다른 지점).
                            startQuickRecording()
                        } label: {
                            Label("다시 녹음", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(quickRecordPhase == .recording || quickRecordPhase == .analyzing)
                    }
                }
            }
        }
    }

    /// 1단계 — 아직 아무것도 캡처하기 전. 다른 패널 없이 화면 중앙에 큰 히어로 버튼+파형만 둬서
    /// "여기서 시작하면 된다"는 게 한눈에 보이게 한다(컴팩트 레이아웃의 카드형과 달리, 넓은
    /// 화면을 살려 더 크게).
    private var regularHeroStage: some View {
        VStack {
            Spacer()
            captureHero(prominent: true)
                .frame(maxWidth: 560)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// 2단계 — 왼쪽(녹음 상태+내 목소리로 화음+채점)/오른쪽(악보, 상시 큼) 두 열.
    private var regularSplitStage: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // showsInlineRetry: false — "다시 녹음"은 이제 툴바가 전담한다. 이 카드 안에도
                    // 같은 이름의 버튼을 남겨두면 툴바 버전과 의미가 갈려서(하나는 컨텍스트 유지,
                    // 하나는 완전 리셋) 헷갈린다.
                    captureHero(prominent: false, showsInlineRetry: false)

                    if melodySession.suggestedHarmony != nil {
                        voiceHarmonyPanel
                        scoringCard
                    }
                }
                .padding()
                .animation(.easeOut(duration: 0.3), value: hasHarmony)
            }
            // 아이폰 카드 폭과 비슷하게 고정 — QuickRecordView 등 기존 서브뷰가 이 폭에서
            // 이미 잘 보이도록 만들어져 있어서(컴팩트 레이아웃과 같은 폭), 그대로 재사용해도
            // 어색하지 않다.
            .frame(width: 380)

            // 두 패널을 선으로 구분 — 프로토타입(아티팩트)에서 왼쪽/오른쪽 패널을 나누던
            // 얇은 세로선과 같은 관례. 카드형 배경(모서리 둥근 회색 배경)만으로는 두 패널이
            // 어디서 나뉘는지 애매했다는 피드백을 반영.
            Divider()

            rightPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }

    /// "다시 녹음" 중(우측 악보는 새 분석이 끝날 때까지 대기 상태)이면 진행 표시를, 아니면
    /// 실제 악보를 보여준다 — 이전 녹음의 악보를 그대로 둔 채 새로 녹음하면 "지금 보이는 게
    /// 방금 부른 거냐, 예전 거냐" 헷갈릴 수 있어서 명확히 구분했다.
    @ViewBuilder
    private var rightPanel: some View {
        if quickRecordPhase == .recording || quickRecordPhase == .analyzing {
            sheetMusicRerecordingPlaceholder
        } else {
            sheetMusicPanel(fillAvailable: true)
        }
    }

    private var sheetMusicRerecordingPlaceholder: some View {
        VStack(spacing: Theme.Spacing.sm) {
            ProgressView()
            Text(quickRecordPhase == .analyzing ? "새로 부른 노래를 분석하는 중이에요" : "다시 녹음하는 중이에요")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 두 레이아웃이 공유하는 섹션

    /// 캡처 영역 — 여기서부터 흐름이 시작된다. 빠른 녹음이 연습의 유일한 진입점이라 카드
    /// 크롬(제목바/테두리) 없이 화면의 주인공이 되는 히어로 레이아웃을 쓴다(QuickRecordView가
    /// 스스로 대기/녹음 중 상태를 꾸민다).
    /// - Parameters:
    ///   - prominent: 아이패드 1단계 대기 화면처럼 이 뷰가 화면의 유일한 주인공일 때 크게.
    ///   - showsInlineRetry: 결과/에러 상태의 "다시 녹음" 인라인 버튼 노출 여부(기본 true, 아이폰은
    ///     항상 유지). 아이패드 2단계에서만 false로 꺼서 툴바의 "다시 녹음"과 의미가 안 겹치게 한다.
    @ViewBuilder
    private func captureHero(prominent: Bool, showsInlineRetry: Bool = true) -> some View {
        if micPermissionDenied {
            micPermissionDeniedContent
        } else {
            VStack(spacing: Theme.Spacing.sm) {
                QuickRecordView(
                    phase: quickRecordPhase,
                    elapsed: Double(quickRecordBuffer.count) / quickRecordSampleRate,
                    maxDuration: quickRecordMaxDuration,
                    waveformSamples: quickRecordBuffer,
                    onStart: startQuickRecording,
                    onStop: stopQuickRecording,
                    onCancel: cancelQuickRecording,
                    onReset: resetSession,
                    prominent: prominent,
                    currentLevel: recordingLevel,
                    showsInlineRetry: showsInlineRetry
                )

                // 녹음 버튼 아래에 작게 — 녹음이 시작되면(또는 이미 결과/에러 상태면) 참고음은
                // 더 이상 의미가 없어서 대기 상태(.idle)일 때만 보여준다.
                if quickRecordPhase == .idle {
                    startingNoteControls
                }
            }
        }
    }

    /// 녹음 전 참고음(첫음)을 골라 들어보는 작은 컨트롤 — 드롭다운(Picker)으로 C3~C6 범위에서
    /// 반음 단위로 고르고(예전 Stepper 범위와 동일, 47절), 재생 버튼을 누르면 그 음을 계속
    /// 재생해서 무반주로 노래를 시작할 때 음정을 잡을 수 있게 한다. 녹음 버튼보다 시선을 끌면
    /// 안 되는 보조 기능이라 카드 배경 없이 작게 둔다. `TonePlayer`는 자체 오디오 엔진이라
    /// 아직 마이크가 켜지기 전(대기 상태)에만 노출되므로 되먹임 걱정이 없다.
    private var startingNoteControls: some View {
        HStack(spacing: Theme.Spacing.xs) {
            // Picker(.menu 스타일)는 눌러야 할 것처럼 안 보인다는 피드백 — 재생 버튼과 똑같이
            // Menu를 직접 써서 harmonyButtonStyle()을 입힌다(리퀴드 글래스 버튼과 동일한
            // 시각적 무게감을 주기 위해 Button과 같은 방식으로 스타일링).
            Menu {
                ForEach(Array(stride(from: 48, through: 84, by: 1)), id: \.self) { midi in
                    Button {
                        startingNoteMIDI = midi
                        startingNotePlayer.setFrequency(NoteNameConverter.frequency(forMIDINote: midi))
                    } label: {
                        Text(NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: midi))?.noteName ?? "?")
                    }
                }
            } label: {
                Label(
                    NoteNameConverter.convert(frequency: NoteNameConverter.frequency(forMIDINote: startingNoteMIDI))?.noteName ?? "?",
                    systemImage: "tuningfork"
                )
                .font(.caption)
            }
            .harmonyButtonStyle()
            .controlSize(.small)
            .accessibilityLabel("첫음 선택")

            Button {
                toggleStartingNotePlayback()
            } label: {
                Image(systemName: isPlayingStartingNote ? "stop.fill" : "play.fill")
                    .font(.caption)
            }
            .harmonyButtonStyle()
            .controlSize(.small)
            .accessibilityLabel(isPlayingStartingNote ? "첫음 재생 정지" : "첫음 듣기")
        }
        .foregroundStyle(.secondary)
    }

    private func toggleStartingNotePlayback() {
        if isPlayingStartingNote {
            startingNotePlayer.stop()
            isPlayingStartingNote = false
            return
        }
        do {
            startingNotePlayer.setFrequency(NoteNameConverter.frequency(forMIDINote: startingNoteMIDI))
            try startingNotePlayer.start()
            isPlayingStartingNote = true
        } catch {
            statusText = "첫음 재생 실패: \(error.localizedDescription)"
        }
    }

    /// 악보(VexFlow 오선보) 카드. `fillAvailable`이 true면(아이패드 오른쪽 패널) 고정 높이
    /// 대신 남은 공간을 꽉 채우고, 이미 상시 크게 보이니 "전체화면으로 크게 보기" 버튼은 뺀다
    /// (그 버튼은 컴팩트 레이아웃에서 좁은 카드 안에 갇힌 악보를 크게 보기 위한 것이었다).
    private func sheetMusicPanel(fillAvailable: Bool) -> some View {
        HarmonyCard("악보", systemImage: "pianokeys") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // 감지된 조성을 악보 위에 같이 보여준다 — "단음/멜로디 부를 때 나왔던 조성을 악보에도
                // 띄워주면 제대로 불렀는지 확인 가능할 것 같다"는 요청. 실시간 캡처와 같은 record()
                // 경로를 그대로 타는 melodySession.detectedKey를 재사용(51절)해서 새 계산 없이 이미
                // 있는 값을 보여주기만 한다.
                if let key = melodySession.detectedKey {
                    Text("감지된 조성: \(key.name)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                // "조성 말고 각각의 음에 대한 정보"(순서대로 어떤 음이 잡혔는지) 요청 —
                // 조성 하나로 뭉뚱그리지 않고 melodySteps에 이미 있는 노트별 이름을 그대로
                // 나열해서, 부른 음과 악보 위치가 실제로 맞는지 눈으로 대조할 수 있게 한다.
                if !melodySteps.isEmpty {
                    Text("감지된 음: " + melodySteps.map(\.noteName).joined(separator: " · "))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                if fillAvailable {
                    scoreViewWithLoadingOverlay
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    scoreViewWithLoadingOverlay
                        .frame(height: VexFlowScoreView.preferredHeight)

                    Button {
                        showingFullScreenScore = true
                    } label: {
                        Label("전체화면으로 크게 보기", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .harmonyButtonStyle()
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: fillAvailable ? .infinity : nil, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: fillAvailable ? .infinity : nil)
    }

    /// 악보(VexFlowScoreView) 위에 로딩 표시를 겹치는 공통 래퍼 — `sheetMusicPanel`의 두 크기
    /// 분기가 똑같이 재사용한다.
    private var scoreViewWithLoadingOverlay: some View {
        ZStack {
            VexFlowScoreView(
                steps: melodySteps,
                mutedVoices: $mutedVoices,
                activeStepIndex: activePlaybackStepIndex,
                onSeekToStep: { seekPlayback(toStep: $0) },
                isRendering: $isScoreRendering
            )
            if isScoreRendering {
                VStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                    Text("악보를 만드는 중이에요")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var voiceHarmonyPanel: some View {
        HarmonyCard("내 목소리로 화음", systemImage: "music.mic", iconColor: Theme.voiceAccent) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                // 버튼보다 먼저 설명을 둬서, 뭘 누르기 전에 "이게 뭘 하는 버튼인지"부터 읽히게 한다.
                Text(String(format: "방금 녹음한 노래를 그대로 베이스/3도/5도로 옮겨서 들려줘요 (확보된 목소리: %.1f초)",
                            Double(recentVoiceBuffer.count) / recentVoiceSampleRate))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                // 성부별 뮤트 토글 — 눌러서 재생에 포함/제외할 성부를 자유롭게 고른다. "내 목소리로
                // 베이스/3도/5도"를 각각 따로 미리듣는 버튼은 이 토글로 성부 하나만 켜고 재생하면
                // 결과가 같아서(오히려 pan까지 적용돼 더 일관됨) 따로 두지 않고 하나로 합쳤다 —
                // 버튼 수를 줄여 카드를 더 단순하게 다듬었다.
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
                    .harmonyButtonStyle(prominent: true)
                    .frame(maxWidth: .infinity)
                    // "지금 쓸 수 있는 녹음이 있는지"만 본다 — isCapturing(마이크가 지금 열려
                    // 있는지)로 막으면, 녹음을 다 마친 뒤(=isCapturing이 이미 false) 정작 이
                    // 버튼을 못 누르는 문제가 있었다(실제로 겪은 버그). isScoreRendering도 같이
                    // 보는 이유는 playHarmonizedVoice의 가드 주석 참고.
                    .disabled(recentVoiceBuffer.isEmpty || isPlaybackBusy || isScoreRendering)

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var scoringCard: some View {
        HarmonyCard("따라 부르기 채점", systemImage: "target") {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                scoringPanel(for: .bass)
                Divider()
                scoringPanel(for: .third)
                Divider()
                scoringPanel(for: .fifth)
            }
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
        .harmonyButtonStyle()
        .tint(isMuted ? .secondary : Theme.tint)
    }

    /// 켜져 있는 성부만 골라 동시에 재생한다 — 예전엔 "전체 화음"(전부 켜짐 고정)과 "화음만
    /// 듣기"(멜로디만 고정으로 꺼짐) 두 버튼으로 나뉘어 있던 걸, 토글로 자유롭게 조합할 수 있게
    /// 일반화했다(로드맵 Phase 4, docs/CONCEPTS.md 53절).
    private var playEnabledVoicesButton: some View {
        Button {
            playHarmonizedVoice(startStepIndex: nil)
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
                .harmonyButtonStyle()
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

    /// "녹음 그만" 버튼(또는 30초 상한 도달 시 자동 호출) — 마이크를 멈추고, 지금까지 모은 녹음
    /// 전체를 RecordingAnalyzer로 한 번에 분석한다. YIN을 윈도우마다 돌리는 무거운 계산이라
    /// Task로 감싸서 메인 스레드가 멈추지 않게 한다.
    private func stopQuickRecording() {
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
        quickRecordPhase = .analyzing
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
        recordingLevel = 0
    }

    /// RecordingAnalyzer의 배치 분석 결과를, 기존 UI가 그대로 소비할 수 있는 상태로 반영한다.
    private func applyQuickRecordResult(_ analyzed: RecordingAnalyzer.AnalyzedRecording) {
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
            quickRecordPhase = .error(String(
                format: "노래가 인식되지 않았어요 — 더 또렷하게 불러서 다시 녹음해주세요 (측정된 최대 음량: %.5f)",
                peakAmplitude
            ))
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
        // "다시 녹음"으로 새 악보 내용이 들어올 때도 다시 "만드는 중" 표시부터 보여준다 —
        // VexFlowScoreView.Coordinator가 새 페이로드의 renderScore 호출이 끝나면 false로 되돌림.
        isScoreRendering = true
        downbeatStepIndices = Self.downbeatStepIndices(from: melodySteps)

        // "내 목소리로 화음"/채점 카드가 그대로 재사용하는 recentVoiceBuffer를 녹음 전체로 채운다 —
        // 이후 3도/5도/전체 화음 버튼을 누르면 이 전체 녹음이 그대로 피치시프트된다.
        recentVoiceBuffer = analyzed.voiceSamples
        recentVoiceSampleRate = analyzed.sampleRate

        hasCapturedNote = true
        quickRecordPhase = .result(noteCount: analyzed.notes.count)
        #if DEBUG
        print("[PracticeView] applyQuickRecordResult 완료 — hasCapturedNote=\(hasCapturedNote), melodySteps=\(melodySteps.count)개, suggestedHarmony=\(melodySession.suggestedHarmony != nil ? "있음" : "nil")")
        #endif
    }

    /// 화음이 계산된 그 음을 기준으로, 목표 interval(3도/5도) 위 주파수까지의 배율(pitchRatio)을 구한다.
    /// 분모는 `lastNote`(진짜 마지막 음)가 아니라 `suggestedHarmonyBaseFrequency`를 써야 한다 —
    /// 녹음이 온음계 밖 음으로 끝나서 화음이 그보다 앞선 음 기준으로 나온 경우, 마지막 음으로
    /// 나누면 화음과 안 맞는 엉뚱한 비율이 나온다(MelodySession.swift 주석 참고).
    ///
    /// `playHarmonizedVoice`가 실제 재생 트랙을 만들 때는 이 값을 쓰지 않는다(스텝마다 자기
    /// 화음으로 따로 계산 — `harmonizedTrack(interval:startStepIndex:startTime:rate:)` 참고).
    /// 여기서는 "화음이 아예 있는지"를 확인하는 가벼운 존재 확인 용도로만 남겨뒀다.
    private func pitchRatio(toInterval interval: ChordGenerator.Interval) -> Double? {
        guard let baseFrequency = melodySession.suggestedHarmonyBaseFrequency,
              let harmony = melodySession.suggestedHarmony,
              let target = harmony.first(where: { $0.interval == interval }) else { return nil }
        return target.frequency / baseFrequency
    }

    /// 성부 하나(베이스/3도/5도)의 재생 트랙을 멜로디 스텝 단위로 만든다. 예전엔 화음 전체를
    /// (마지막 음 기준) 고정 비율 하나로 통째로 옮겼는데, 여러 음으로 된 멜로디에서는 음마다
    /// 실제 화음이 다른데 비율은 하나로 고정돼 있어서 앵커 음이 아닌 나머지 음들에서 화음이
    /// 어긋나 불협화음처럼 들렸다("메인 멜로디는 괜찮은데 화음이 거슬린다" 실사용 피드백으로
    /// 원인 확정). 이제 각 스텝을 자기 구간(`onsetTime`~`onsetTime+duration`)만큼만 잘라서 그
    /// 스텝 자신의 화음 목표 주파수로 각각 피치시프트한 뒤 이어붙인다. 스텝에 이 성부의 화음이
    /// 없으면(온음계 밖 음 등, 악보에도 쉼표로 표시되는 것과 같은 경우) 무음으로 채워서 재생
    /// 타이밍(재생헤드 매핑, 멜로디 트랙과의 동기)은 그대로 유지한다 — 스텝 사이의 빈틈도
    /// 무음으로 메워서, 결과 트랙 길이가 `recorded`(멜로디 트랙)와 정확히 같게 만든다.
    private func harmonizedTrack(interval: ChordGenerator.Interval, startStepIndex: Int?, startTime: Double, rate: Double) -> [Float] {
        let startIndex = startStepIndex ?? 0
        guard melodySteps.indices.contains(startIndex) else { return [] }

        // 세그먼트 경계에서 나는 클릭음을 없애는 짧은 페이드 — 트랙 전체에 거는 fade보다
        // 훨씬 짧게(1/3 정도)만 줘서, 음이 여러 개 짧게 이어질 때 소리가 너무 죽지 않게 한다.
        let segmentFadeCount = max(1, Int(rate * voiceClipFadeDuration / 3))
        let bufferEnd = recentVoiceBuffer.count
        var output: [Float] = []
        var cursor = max(0, min(bufferEnd, Int(startTime * rate)))

        for i in startIndex..<melodySteps.count {
            let step = melodySteps[i]
            guard let onset = step.onsetTime, let duration = step.duration, duration > 0 else { continue }
            let segStart = max(0, Int(onset * rate))
            let segEnd = min(bufferEnd, Int((onset + duration) * rate))
            guard segStart < segEnd else { continue }

            if segStart > cursor {
                output.append(contentsOf: [Float](repeating: 0, count: segStart - cursor))
            }

            let segment = Array(recentVoiceBuffer[segStart..<segEnd])
            if let target = step.harmony?.first(where: { $0.interval == interval }) {
                let ratio = target.frequency / NoteNameConverter.frequency(forMIDINote: step.midiNote)
                let shifted = PitchShifter.shift(samples: segment, pitchRatio: ratio, formantRatio: interval.formantRatio, sampleRate: rate)
                output.append(contentsOf: AudioGain.applyFadeInOut(shifted, fadeSampleCount: min(segmentFadeCount, shifted.count / 2)))
            } else {
                output.append(contentsOf: [Float](repeating: 0, count: segment.count))
            }
            cursor = segEnd
        }

        if cursor < bufferEnd {
            output.append(contentsOf: [Float](repeating: 0, count: bufferEnd - cursor))
        }
        return output
    }

    /// "내 목소리로 화음 만들기" — 방금 녹음한 소리(recentVoiceBuffer)를 `mutedVoices`에 안
    /// 들어있는(=켜진) 성부만 골라 베이스/3도/5도(+멜로디)로 피치 시프트해서 한꺼번에 동시
    /// 재생한다. 예전엔 "전체 화음"(고정 4성부)/"화음만 듣기"(멜로디 고정 제외)/"베이스·3도·
    /// 5도 각각 미리듣기" 여러 버튼으로 나뉘어 있던 걸, 토글 하나로 자유롭게 조합할 수 있게
    /// 일반화했다(로드맵 Phase 4, docs/CONCEPTS.md 53절).
    ///
    /// `startStepIndex`가 있으면(악보 탭, 74절) 그 스텝의 onsetTime부터 재생한다 — 버튼(항상
    /// nil, 처음부터)과 탭(구체적 인덱스)이 같은 파이프라인을 공유한다. 재생 시작 지점만
    /// `recentVoiceBuffer`를 그 지점부터 잘라서 넣는 걸로 바뀌고, 나머지(정규화/시프트/더블링)는
    /// 그대로다.
    private func playHarmonizedVoice(startStepIndex: Int?) {
        // 녹음 직후엔 악보 렌더링(WKWebView가 VexFlow로 레이아웃 계산하는 무거운 JS 작업)과
        // 화음 피치시프트(WORLD 연산)가 동시에 실기기 CPU를 다투게 되는데, 그 여파로 재생 오디오
        // 콜백이 밀려 소리가 끊기는 문제가 있었다("녹음 듣는데 음이 끊긴다" 실기기 제보) — 악보가
        // 완전히 그려질 때까지는(isScoreRendering이 꺼질 때까지) 재생 자체를 시작하지 않는다.
        // 버튼(playEnabledVoicesButton)은 .disabled로 같은 조건을 미리 막지만, 악보 탭(seekPlayback)은
        // 버튼이 아니라 JS 쪽 이벤트라 여기서도 같이 막아야 한다.
        guard !isScoreRendering else {
            statusText = "악보를 그리는 중이에요 — 완료되면 다시 눌러주세요"
            return
        }
        let isSeek = startStepIndex != nil
        if isPlaybackBusy {
            // 탭으로 인한 재생은 "다른 소리가 재생 중이면 거부" 가드를 우회하고, 대신 지금
            // 재생 중인 소리를 끊고 그 자리에서 새로 시작한다 — 애플 뮤직에서 재생 중에 다른
            // 가사를 탭하면 바로 그리로 이동하는 것과 같은 동작.
            guard isSeek else {
                statusText = "다른 소리가 재생 중이에요 — 끝난 뒤 다시 눌러주세요"
                return
            }
            voiceClipPlayer.stop()
        }
        guard melodySession.suggestedHarmony != nil else {
            statusText = "아직 화음이 없어요 — 먼저 녹음해주세요"
            return
        }
        // 이후 실제 트랙은 스텝마다 자기 화음으로 따로 계산한다(harmonizedTrack) — 여기서는
        // "화음 자체가 있는지"만 가볍게 확인한다.
        guard pitchRatio(toInterval: .bass) != nil,
              pitchRatio(toInterval: .third) != nil,
              pitchRatio(toInterval: .fifth) != nil else {
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

        let startTime: Double
        if let index = startStepIndex, melodySteps.indices.contains(index), let onset = melodySteps[index].onsetTime {
            startTime = onset
        } else {
            startTime = 0
        }
        let startSampleIndex = min(recentVoiceBuffer.count, max(0, Int(startTime * recentVoiceSampleRate)))
        let recorded = Array(recentVoiceBuffer[startSampleIndex...])
        let rate = recentVoiceSampleRate
        let muted = mutedVoices
        statusText = "화음 만드는 중…"

        playbackGeneration += 1
        let generation = playbackGeneration

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
            // 베이스(한 옥타브 아래) + 3도 + 5도 트랙을 만든다 — 스텝마다 자기 화음 목표로 따로
            // 피치시프트한다(harmonizedTrack, 멜로디가 여러 음일 때 화음이 어긋나던 문제 수정,
            // docs/CONCEPTS.md 81절). 꺼진 성부는 계산 자체를 건너뛴다(WORLD 분석은 가볍지
            // 않아서, 안 쓸 트랙까지 굳이 만들 필요 없음).
            for (voice, interval) in [(PlaybackVoice.bass, ChordGenerator.Interval.bass),
                                       (.third, .third),
                                       (.fifth, .fifth)] where !muted.contains(voice) {
                let shifted = harmonizedTrack(interval: interval, startStepIndex: startStepIndex, startTime: startTime, rate: rate)
                guard !shifted.isEmpty else { continue }
                // 성부마다 다른 지연/디튠으로 더블링해서 두께를 준다 — 멜로디(원음)는 그대로 둔다.
                // 이미 사용자 자신이 직접 부른 진짜 목소리라 "다른 사람이 한 번 더 부른" 효과가
                // 필요 없고, 오히려 원음이 흔들리면 리드로서의 기준점이 흐려진다.
                let doubled = VoiceDoubler.apply(to: shifted, sampleRate: rate, interval: interval)
                tracks.append((prepare(doubled), interval.pan))
            }

            do {
                isPlayingVoiceClip = true
                // 재생 시작 직후 첫 스텝 전환에서부터 지연 없이 울리도록, 애플이 권장하는 대로
                // 실제 impactOccurred() 호출 전에 미리 준비해둔다.
                downbeatHaptic.prepare()
                upbeatHaptic.prepare()
                // 실제 시작 시각이 아니라 startTime만큼 과거로 앞당긴 시각을 기준점으로 삼는다 —
                // updatePlaybackStepIndex()가 "지금 - 이 시각"으로 경과 시간을 구해서 그대로
                // melodySteps의 onsetTime/duration과 비교하므로, 이렇게 하면 잘라낸 지점부터
                // 재생해도 원본 녹음 타임라인 기준 경과 시간이 계속 정확하게 나온다(한 줄도
                // 안 고치고 재사용 가능).
                voiceClipPlaybackStartedAt = Date().addingTimeInterval(-startTime)
                try voiceClipPlayer.playTracks(tracks, sampleRate: rate) {
                    guard generation == playbackGeneration else { return }
                    isPlayingVoiceClip = false
                    voiceClipPlaybackStartedAt = nil
                    activePlaybackStepIndex = nil
                }
                statusText = "내 목소리로 만든 화음을 재생합니다"
            } catch {
                guard generation == playbackGeneration else { return }
                isPlayingVoiceClip = false
                voiceClipPlaybackStartedAt = nil
                activePlaybackStepIndex = nil
                statusText = "재생 실패: \(error.localizedDescription)"
            }
        }
    }

    /// 악보의 음표를 탭했을 때(`VexFlowScoreView.onSeekToStep`) 호출된다 — 그 지점부터
    /// 재생을 시작하는 얇은 래퍼.
    private func seekPlayback(toStep index: Int) {
        playHarmonizedVoice(startStepIndex: index)
    }

    /// 재생헤드 타이머(playheadTimer)가 50ms마다 부른다 — 재생 중이 아니면(voiceClipPlaybackStartedAt이
    /// nil) 즉시 return. 재생 경과 시간이 melodySteps의 어느 스텝 구간(onsetTime~onsetTime+duration)에
    /// 속하는지 찾아서 activePlaybackStepIndex에 반영하면, VexFlowScoreView가 그 인덱스를 받아
    /// 재생헤드 세로선을 옮긴다.
    private func updatePlaybackStepIndex() {
        guard let startedAt = voiceClipPlaybackStartedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        activePlaybackStepIndex = melodySteps.firstIndex { step in
            guard let onset = step.onsetTime, let duration = step.duration else { return false }
            return elapsed >= onset && elapsed < onset + duration
        }
    }

    /// `activePlaybackStepIndex`가 바뀔 때마다(.onChange) 불린다 — 재생이 멈추거나(nil로
    /// 바뀔 때) 시작 직전(nil에서 처음 값이 잡히는 순간 포함)에도 자연스럽게 한 번 울리는
    /// 정도라 굳이 nil을 걸러낼 필요는 없고, index 자체가 nil이면 그냥 아무 것도 안 한다.
    private func triggerStepHaptic(for index: Int?) {
        guard let index else { return }
        if downbeatStepIndices.contains(index) {
            downbeatHaptic.impactOccurred()
        } else {
            upbeatHaptic.impactOccurred()
        }
    }

    /// 마디의 첫 박(다운비트) 스텝 인덱스만 모은다 — `RhythmQuantizer.measureBreaks`가 이미
    /// "마디마다 음이 몇 개인지"를 계산해주므로, 각 구간의 시작 인덱스만 누적하면 된다.
    /// `VexFlowScoreView.buildPayload`가 악보를 그릴 때 쓰는 것과 같은 계산을 여기서도 한 번
    /// 더 돌린다 — `activePlaybackStepIndex`가 `melodySteps`(필터링 전) 인덱스를 그대로
    /// 쓰므로, 여기서도 필터링 없이 `melodySteps` 전체 길이 기준으로 맞춘다.
    private static func downbeatStepIndices(from melodySteps: [MelodyStep]) -> Set<Int> {
        let quantized = RhythmQuantizer.quantize(durations: melodySteps.map { $0.duration ?? 0.3 })
        let measureBreaks = RhythmQuantizer.measureBreaks(notes: quantized)
        var indices: Set<Int> = []
        var cursor = 0
        for count in measureBreaks {
            if count > 0 { indices.insert(cursor) }
            cursor += count
        }
        return indices
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
        voiceClipPlaybackStartedAt = nil
        activePlaybackStepIndex = nil
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
        recordingLevel = 0
    }
}
