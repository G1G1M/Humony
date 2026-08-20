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
    // 있도록 60초로 늘렸다(기존 30초). WSOLA 피치시프트 비용은 프레임별로 선형이라 시간이
    // 늘어도 체감 지연은 크지 않고, 분석 쪽 안전망은 별도로 12초 타임아웃(stopQuickRecording)을 둔다.
    let quickRecordMaxDuration: Double = 60.0
    // "12초 타임아웃 적용" — 60초 분량 녹음도 분석이 이보다 오래 걸리면 타임아웃 처리한다.
    let analysisTimeout: TimeInterval = 12.0

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
    // 3도/5도를 각각 독립적으로 채점한다 — 하나 채점하다 다른 쪽으로 넘어가도
    // 이전 것의 최근 결과(latestScores)는 화면에 그대로 남아있는다. 실제로 마이크가
    // 매 순간 채점하는 대상은 하나(activeScoringInterval)뿐이지만, 그 결과와 사람이 부르는
    // 동안 쌓인 샘플은 interval별로 따로 보관해서 서로 덮어쓰지 않게 한다.
    @State var activeScoringInterval: ChordGenerator.Interval?
    @State var lockedScoringTargets: [ChordGenerator.Interval: ChordGenerator.HarmonyNote] = [:]
    @State var latestScores: [ChordGenerator.Interval: PitchScorer.Score] = [:]
    @State var scoreSampleBuffers: [ChordGenerator.Interval: [PitchScorer.Score]] = [:]
    // 명세서(v1.0) "3프레임(약 140ms) 유지 확정 시 경쾌한 햅틱" — 단음 캡처 모드의 "3프레임
    // 연속 유지" 확정 관례(CLAUDE.md)와 같은 프레임 수 기준을 채점에도 적용한다. 허용오차
    // 진입 프레임이 연속될 때만 세되, 한 번 울리면 그 연속 구간 안에서는 다시 안 울리게
    // `onPitchHapticFired`로 막는다(계속 정확한 음을 유지하는 동안 매 프레임 울리면 시끄럽다) —
    // 다시 벗어났다 맞히면 새 연속 구간으로 취급해 다시 한 번 울린다.
    @State var onPitchStreak: [ChordGenerator.Interval: Int] = [:]
    @State var onPitchHapticFired: [ChordGenerator.Interval: Bool] = [:]
    let scoringSuccessHaptic = UINotificationFeedbackGenerator()

    // 첫 녹음 분석이 끝났는지 — 점진적 공개("내 목소리로 화음"/"따라 부르기 채점" 카드 등장
    // 여부) 판단에 쓴다. melodySteps 자체(음이름+옥타브+화음+시작시각/길이)는 지금은 화면에
    // 직접 표시하지 않지만(조성/화음 요약 카드는 제거했다 — 지금 단계에선 필요 없다는 판단),
    // 다음 단계인 악보 렌더링에 그대로 필요한 데이터라 계속 계산해서 들고 있는다.
    @State var hasCapturedNote = false
    // 채점 카드는 접힌 상태로 시작한다 — PRODUCT.md 원칙3("채점은 화면 위계에서 영구히 중심일
    // 필요 없다")이 실제 화면엔 반영 안 돼 있었다는 크리틱 지적(P1) 반영. "내 목소리로 화음"
    // 카드와 똑같은 크기/제목 굵기로 자동으로 펼쳐지던 걸, 펼쳐야 보이는 가벼운 한 줄 디스클로저로
    // 낮췄다 — 화음 체험을 먼저 끝낸 사람만 일부러 채점으로 넘어가는 흐름.
    @State var isScoringExpanded = false
    // "중지"를 눌러 채점 시도가 저장된 직후에만 잠깐 확인 메시지를 보여준다 — 예전엔 저장이
    // 조용히 끝나서 정말 기록됐는지 알 방법이 없었다(크리틱 P3). 새 채점을 시작하거나 새로
    // 녹음하면 지운다.
    @State var lastSavedInterval: ChordGenerator.Interval?
    @State var melodySteps: [MelodyStep] = []
    // 방금 녹음한 목소리 원본 — "녹음 다시 듣기"(원본 그대로 재생, 117절)와
    // "내 목소리로 화음 듣기"(123절, VoiceHarmonyTrackBuilder가 이 버퍼에서 음마다 슬라이싱해
    // 피치시프트하는 소스)에 둘 다 쓰인다.
    @State var recentVoiceBuffer: [Float] = []
    @State var recentVoiceSampleRate: Double = 44100
    let recordingPlayer = RecordingPlayer()
    @State var isPlayingRecording = false
    // 120절, 화음 재설계 — 멜로디+베이스+3도+5도를 합성음으로 섞어 재생하는 전용 플레이어.
    // recordingPlayer(원본 재생)와 별개 인스턴스를 쓰는 이유: 둘을 같은 인스턴스로 공유하면
    // "녹음 다시 듣기"와 "화음 듣기"를 빠르게 번갈아 누를 때 서로의 재생을 끊어버릴 수 있다.
    let harmonyPlayer = RecordingPlayer()
    @State var isPlayingHarmony = false
    // 123절, 화음 재설계 2단계 — 목소리 피치시프트(WSOLA) 버전 전용 플레이어. 합성음 버전
    // (harmonyPlayer)과 별개 인스턴스로 둬서 둘을 번갈아 눌러도 서로 끊기지 않게 한다.
    let voiceHarmonyPlayer = RecordingPlayer()
    @State var isPlayingVoiceHarmony = false
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
    let pitchSmoother = PitchSmoother()

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
            recordingPlayer.stop()
            isPlayingRecording = false
            harmonyPlayer.stop()
            isPlayingHarmony = false
            voiceHarmonyPlayer.stop()
            isPlayingVoiceHarmony = false
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
