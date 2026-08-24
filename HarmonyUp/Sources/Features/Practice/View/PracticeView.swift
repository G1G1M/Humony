import SwiftUI
import SwiftData
import AVFAudio
import UIKit
import Combine

/// "연습" 탭 — 빠른 녹음으로 노래 한 소절을 받아 멜로디를 인식하고 악보로 보여준다.
///
/// **2026-08-20, 화음 재설계(120절)**: 화음 생성/재생(피치시프트, 합성음, WORLD 등)이
/// "화음이 이상하게 들린다"는 문제를 여러 라운드(93~115절) 반복해도 못 풀어서, 116절에서
/// 한 번 전부 걷어내고 "멜로디를 제대로 뽑아내는 것"부터 다시 다졌다(117~119절, 실기기
/// 검증 완료). 120절부터 화음을 처음부터 다시 쌓는 중 — 목소리 피치시프트는 배제하고
/// `ToneSynthesizer`(순수 사인파) + `SynthesizedHarmonyTrackBuilder`로 멜로디+베이스+3도+5도를
/// 전부 합성음으로 만들어 "화음 듣기" 버튼 하나로 재생한다("화음 선택/타이밍이 맞는지"부터
/// 변수를 격리해 검증하는 게 목적, 목소리 버전은 그 다음 단계). 채점 관련 파일
/// (`PracticeView+Scoring.swift`, `PitchScorer`, `PracticeSummary`, `PracticeAttempt`,
/// `HistoryView`)은 여전히 화면에는 안 뜨게 빼둔 채다 — 화음 재생이 다시 자리잡은 뒤 순서를
/// 다시 논의할 대상.
///
/// **파일 구성**: 상태 선언과 `body`는 여기, 나머지 책임은 각각 `PracticeView+Layout.swift`
/// (화면 레이아웃+캡처/악보 UI), `PracticeView+Scoring.swift`(따라 부르기 채점, 지금은
/// UI에서 숨김), `PracticeView+Capture.swift`(녹음/분석)로 나눠져 있다. Swift의 `private`는
/// 선언된 파일 밖(다른 파일의 extension 포함)에서는 안 보이므로, 다른 파일에서 참조하는 상태/
/// 메서드는 대부분 `private` 없이(모듈 내부 전용인 internal로) 선언한다 — 앱 타깃 밖으로는
/// 여전히 노출되지 않는다.
struct PracticeView: View {
    @Environment(\.modelContext) var modelContext
    // 아이패드(또는 가로모드 대화면 아이폰)에서 왼쪽=녹음/재생/채점, 오른쪽=악보(상시 큼) 두 열
    // 레이아웃으로 바꾸는 기준. 기기 종류(UIDevice.userInterfaceIdiom)가 아니라 실제 표시 폭으로
    // 판단하는 게 애플이 권장하는 적응형 방식이라, 아이패드 Split View로 좁아지면 자동으로 아이폰
    // 방식으로 폴백되고 반대로 대화면 아이폰 가로모드에서도 자연스럽게 두 열이 적용된다.
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    // 카드 등장 애니메이션(아래 cardAppearTransition)이 이 설정을 존중하게 한다 — 켜져 있으면
    // 밀려 들어오는 움직임(.move) 없이 페이드만 남긴다(Apple 권장: 슬라이드/패럴랙스 대신
    // 크로스페이드로 대체). 크리틱 P2에서 앱 전체에 이 대응이 전혀 없다고 지적받음.
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// 카드가 새로 나타날 때 쓰는 공용 트랜지션 — Reduce Motion이 켜져 있으면 이동 없이
    /// 페이드만 쓴다.
    var cardAppearTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    // 빠른 녹음 전용 상태 — 녹음 전체를 모았다가 멈춘 뒤 한 번에 RecordingAnalyzer로 분석한다.
    @State var quickRecordPhase: QuickRecordView.Phase = .idle
    @State var quickRecordBuffer: [Float] = []
    @State var quickRecordSampleRate: Double = 44100
    // 타임아웃으로 먼저 에러 처리된 뒤에도 백그라운드에서 계속 돌던 이전 분석 Task가 뒤늦게
    // 끝나 결과를 덮어써버리는 걸 막는 세대 토큰 — 매 stopQuickRecording()마다 새로 발급하고,
    // 분석 완료 시점에 지금 발급된 토큰과 같을 때만 그 결과를 반영한다.
    @State var activeAnalysisToken: UUID?
    // 명세서(v1.0) "최대 녹음 시간 확장" — 한 구절(Verse)/후렴구(Chorus)를 넉넉하게 부를 수
    // 있도록 60초로 늘렸다(기존 30초). 분석이 오래 걸려도 메인 스레드를 막지 않으므로
    // (`stopQuickRecording`이 `Task.detached`로 돌린다) 길이 자체는 부담이 되지 않는다.
    let quickRecordMaxDuration: Double = 60.0

    // 녹음 전 참고음(첫음) 골라 듣기 — 무반주로 노래를 시작할 때 음정을 잡기 위한 순수 참고용
    // 기능이다. 예전엔 "조성과 화음" 카드 안에 있었는데(54절에서 카드째 정리) 사용자가 다시
    // 요청해서 복원한다 — 이번엔 분석 파이프라인과 완전히 분리된 채로(melodySession 등은
    // 전혀 안 건드림), 녹음 시작 전에만 보이는 별도 컨트롤로 둔다.
    @State var startingNoteMIDI: Int = 60 // C4, 항상 도로 시작하도록 고정(74절)
    @State var isPlayingStartingNote = false
    let startingNotePlayer = TonePlayer()
    // 녹음 중 마이크 헤일로 애니메이션용 실시간 음량(0~1로 정규화). VoiceActivityDetector와 같은
    // 방식(제곱평균제곱근)으로 매 프레임 계산해서 QuickRecordView에 넘긴다.
    @State var recordingLevel: Float = 0
    // 정상적으로 노래할 때 나올 법한 RMS 상한 — 이걸로 나눠서 0~1로 정규화한다. 아이패드
    // 실기기에서 가까이 대고 불러도 최대 진폭(peak)이 0.01 안팎으로 실측됐다(stopQuickRecording
    // 참고, "노래 인식 안 됨" 진단 과정에서 추측 아닌 실측으로 확인됨) — RMS는 보통 peak보다
    // 낮으므로(사인파 기준 peak/√2, 실제 발성은 더 낮음) 그보다 한 자릿수 작게 잡았다. 기기별
    // 마이크 게인 차이가 있을 수 있어 여전히 시작점 — 헤일로가 너무 안 커지거나 바로 최대치로
    // 붙어버리면 이 값을 조정하면 된다.
    let recordingLevelNormalization: Float = 0.006

    // 마이크가 지금 실제로 열려 있는지(오디오 엔진이 돌고 있는지)만 추적하는 내부 플래그다 —
    // beginCapturingIfNeeded()의 중복 시작 방지용일 뿐, UI 활성/비활성 판단에는 쓰지 않는다.
    // 녹음이 끝나면 곧바로 false가 되므로, "내 목소리로 화음" 같은 버튼을 이 값으로 막으면
    // 정작 다 녹음해놓고도 버튼이 눌리지 않는 버그가 생긴다(실제로 겪은 문제).
    @State var isCapturing = false
    // 마이크 권한이 꺼진 상태는 버튼을 누르기도 전에(onAppear에서) 미리 감지해서 전용 UI로 보여준다.
    @State var micPermissionDenied = false

    // 녹음/재생 관련 짧은 피드백 메시지 — 가드 조건에 걸렸을 때 "왜 안 되는지"를 "내 목소리로 화음"
    // 카드에 알려주는 용도로만 쓴다. 결과/성공 메시지도 여기 담긴다.
    @State var statusText = ""
    // 136절, 채점 재설계 — "성부 하나를 골라 먼저 들어보고, 소리를 끄고, 그 성부 한 소절을
    // 통째로 불러서 배치로 채점한다". 예전 채점은 목표음 하나를 붙잡고 지속 발성하는 실시간
    // 프레임 채점이었는데(activeScoringInterval / latestScores / onPitchStreak 등), 이 앱의
    // 목표는 한 음을 배우는 게 아니라 화음 한 소절을 부르는 것이라 흐름째 바꿨다. 재생과 녹음이
    // 시간상 절대 겹치지 않으므로 마이크 피드백 가드(startCaptureAfterPermissionGranted)를
    // 그대로 두고도 안전하다.
    @State var scoringVoice: ChordGenerator.Interval = .third
    @State var scoringPhase: ScoringPhase = .idle
    @State var scoringBuffer: [Float] = []
    @State var scoringSampleRate: Double = 44100
    @State var scoringResult: HarmonyPracticeScorer.Result?
    // 화면에 보이는 결과가 어느 성부의 것인지 — 결과를 본 뒤 다른 성부를 골라도 이전 결과가
    // 그 성부의 것처럼 보이지 않게 같이 들고 있는다.
    @State var scoringResultVoice: ChordGenerator.Interval?
    // 빠른 녹음 쪽 activeAnalysisToken과 같은 이유의 세대 토큰 — 뒤늦게 끝난 이전 채점 분석이
    // 새 시도의 결과를 덮어쓰지 않게 한다.
    @State var activeScoringToken: UUID?
    // 이번 녹음에 대응하는 기록 세션 — 같은 녹음에서 성부를 바꿔 여러 번 채점하면 하나의 세션
    // 아래에 시도가 쌓이게 하려고 들고 있는다. 첫 채점이 끝날 때 만들어지고(채점을 한 번도 안
    // 하면 세션도 안 남는다 — 녹음만 하고 만 것을 기록으로 남길 이유가 없다), 새로 녹음하면 비운다.
    @State var currentSession: PracticeSession?
    // 채점이 끝난 순간 한 번 울린다(실시간 프레임 햅틱은 이 흐름에선 의미가 없어졌다).
    let scoringSuccessHaptic = UINotificationFeedbackGenerator()

    /// 채점 흐름의 단계 — 빠른 녹음(`QuickRecordView.Phase`)과 같은 방식으로, 지금 화면에
    /// 무엇을 보여줄지를 이 하나로 결정한다.
    enum ScoringPhase: Equatable {
        case idle
        case recording
        case analyzing
        case result
        case error(String)
    }

    // 첫 녹음 분석이 끝났는지 — 점진적 공개("내 목소리로 화음"/"따라 부르기 채점" 카드 등장
    // 여부) 판단에 쓴다. melodySteps 자체(음이름+옥타브+화음+시작시각/길이)는 지금은 화면에
    // 직접 표시하지 않지만(조성/화음 요약 카드는 제거했다 — 지금 단계에선 필요 없다는 판단),
    // 다음 단계인 악보 렌더링에 그대로 필요한 데이터라 계속 계산해서 들고 있는다.
    @State var hasCapturedNote = false
    // 136절 — 채점 카드의 여닫기(isScoringExpanded / scoringDisclosureRow)를 없앴다. "성부별로
    // 듣기"를 항상 펼치기로 바꾼 것(135절)과 같은 이유이고, "바로 불러서 채점할 수 있게" 요청
    // 그대로다 — 채점은 이제 화음을 들어본 다음 자연스럽게 이어지는 단계라 숨겨둘 이유가 없다.
    @State var melodySteps: [MelodyStep] = []
    // 방금 녹음한 목소리 원본 — "내 목소리로 화음 듣기"(123절, VoiceHarmonyTrackBuilder가 이
    // 버퍼에서 음마다 슬라이싱해 피치시프트하는 소스)에 쓰인다.
    @State var recentVoiceBuffer: [Float] = []
    @State var recentVoiceSampleRate: Double = 44100
    // 123절, 화음 재설계 2단계 — 목소리 피치시프트(WORLD) 버전 전용 플레이어.
    let voiceHarmonyPlayer = RecordingPlayer()
    @State var isPlayingVoiceHarmony = false
    // 135절 — 재생 조작부에서 "원본"/"내 목소리" 두 섹션을 하나로 합쳤다("화음은 내 목소리로도
    // 들을 수 있으니 원본은 굳이 따로 없어도 된다"는 판단) — 세그먼트 선택 상태(PlaybackMode)와
    // 원본 전용 재생(recordingPlayer/isPlayingRecording/togglePlayback)은 이제 안 쓰여서 함께
    // 제거했다.
    // 135절 — 성부별 솔로/뮤트 4행을 더 이상 접지 않고 항상 펼쳐서 보여준다("열었다 닫았다 하지
    // 말고 처음부터 보이게" 요청) — isVoiceDisclosureExpanded 제거.
    // 128절 — 어느 성부가 음소거됐는지, 그리고 "재생 중 뮤트 전환으로 재시작"에서 낡은 완료
    // 콜백이 새 재생 상태를 덮어쓰지 않게 막는 세대 토큰(startVoiceHarmonyPlayback 참고).
    @State var mutedVoices: Set<VoiceHarmonyTrackBuilder.Voice> = []
    @State var voiceHarmonyPlaybackGeneration = UUID()
    // 화음 트랙을 만드는 동안(WORLD 분석+재합성) 켜진다 — 예전엔 이 작업이 버튼 액션 안에서
    // 동기로 돌아 60초 녹음이면 소리가 나기 전까지 화면이 통째로 멈춰 있었다(스피너조차 없이).
    // 이제 백그라운드로 옮겼고, 그동안 무슨 일이 일어나는지 이 값으로 알린다.
    @State var isPreparingHarmony = false
    // 128절 — 멜로디/베이스/3도/5도를 각각 따로 들어볼 수 있는 개별 재생 버튼(성부별 디버깅/비교
    // 용도로 예전에도 있었던 기능, WORLD 버전 위에 다시 만듦). 동시에 하나만 재생되므로 "지금
    // 재생 중인 성부가 뭔지"만 옵셔널 하나로 추적한다.
    let soloVoicePlayer = RecordingPlayer()
    @State var playingSoloVoice: VoiceHarmonyTrackBuilder.Voice?
    // 악보 카드가 뜬 시점엔 항상 true로 시작 — WKWebView 프로세스가 늦게 뜰 수 있어서(76절),
    // 첫 렌더가 끝날 때까지는 화면이 비어 보이는 대신 "만드는 중" 표시를 겹쳐 보여준다.
    // VexFlowScoreView.Coordinator가 renderScore 자바스크립트 호출이 끝나면 false로 되돌린다.
    @State var isScoreRendering = true
    // 악보 "내용"이 실제로 바뀔 때만 올라가는 세대 번호 — `VexFlowScoreView.contentVersion`으로
    // 그대로 전달된다. 재생 중엔 activePlaybackStepIndex만 바뀌어서 body가 초당 최대 20번
    // 재평가돼도 이 값은 그대로라야 한다 — applyQuickRecordResult(새 녹음 반영)와 mutedVoices
    // 변경(.onChange, 아래 body) 두 곳에서만 올린다.
    @State var scoreContentVersion = 0
    // 악보 카드는 다른 카드들과 나란히 있어서 고정 높이 안에 좁게 보인다 — 렌더링이 제대로
    // 되는지 크게 확인하고 싶을 때 이 상태로 전체화면 뷰(SheetMusicFullScreenView)를 띄운다.
    @State var showingFullScreenScore = false
    // 명세서(v1.0) "퀵 스왑" — 아이패드/가로모드 2단 분할에서 조작부(캡처+내목소리화음+채점)와
    // 악보부의 좌우 위치를 헤더 버튼으로 즉시 전환한다(왼손/오른손잡이·DAW 사용자 습관 대응).
    // true면 조작부가 왼쪽(기존 기본 배치), false면 오른쪽.
    @State var isControlPanelLeading = true

    let audioCapture = AudioCapture()
    let melodySession = MelodySession()
    // 136절 — `PitchSmoother`(프레임별 피치 흔들림 완화)는 실시간 프레임 채점 전용이었다.
    // 채점이 "다 부른 뒤 배치로 세그멘테이션"하는 방식이 되면서 스무딩할 프레임 스트림 자체가
    // 없어져 인스턴스를 걷어냈다 — 타입은 남겨둔다(`MelodySegmenter`가 같은 목적을 중앙값
    // 필터로 이미 하고 있고, 실시간 미터를 다시 붙일 때를 위해 `PitchMeterView`와 함께 보존).

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .tint(Theme.tint)
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
            voiceHarmonyPlayer.stop()
            isPlayingVoiceHarmony = false
            isPreparingHarmony = false
            soloVoicePlayer.stop()
            playingSoloVoice = nil
            startingNotePlayer.stop()
            isPlayingStartingNote = false
        }
        .fullScreenCover(isPresented: $showingFullScreenScore) {
            SheetMusicFullScreenView(steps: melodySteps, detectedKeyName: melodySession.detectedKey?.name)
        }
    }
}
