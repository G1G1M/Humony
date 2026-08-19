import SwiftUI
import SwiftData
import AVFAudio
import UIKit
import Combine

/// "연습" 탭 — 빠른 녹음으로 노래 한 소절을 받아 조성/화음 판별 -> 화음 청취(합성음/내 목소리) ->
/// 채점까지 한 세션의 흐름을 담당한다. 예전엔 이 화면 자체가 앱의 유일한 화면(`ContentView`)이었는데,
/// 세션 기록(`HistoryView`)을 별도 탭으로 분리하면서 이름도 역할에 맞게 바꿨다. 예전엔 "단음"/"멜로디"
/// 실시간 캡처 모드도 별도로 있었지만, 빠른 녹음이 그 기능(여러 음을 이어 부른 멜로디)을 그대로
/// 포함하면서 데이터 흐름이 더 명확해져서(녹음 완료 -> 분석 -> 결과, 프레임 단위로 상태가 섞이지
/// 않음) 하나로 통합했다.
///
/// **파일 구성**: 상태 선언과 `body`는 여기, 나머지 책임은 각각 `PracticeView+Layout.swift`
/// (화면 레이아웃+캡처/악보 UI), `PracticeView+VoiceHarmony.swift`(내 목소리로 화음 재생),
/// `PracticeView+Scoring.swift`(따라 부르기 채점), `PracticeView+Capture.swift`(녹음/분석)로
/// 나눠져 있다 — 파일 하나가 1400줄 넘게 불어나 있던 걸 책임별로 쪼갰다. Swift의 `private`는
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

    // "내 목소리로 화음 만들기" — 합성음(TonePlayer) 대신 사용자 목소리를 그대로 베이스/3도/5도로
    // 옮겨서 재생한다. 빠른 녹음이 끝나면 녹음 전체가 그대로 여기 채워진다(applyQuickRecordResult).
    @State var recentVoiceBuffer: [Float] = []
    @State var recentVoiceSampleRate: Double = 44100
    // 성부별(베이스/3도/5도) 화음 트랙(WORLD 피치시프트 결과) 사전 계산 캐시 — 녹음 전체
    // (startStepIndex: nil, startTime: 0 기준)를 키로 한 번만 담아두고, 재생/탭-탐색은 여기서
    // 필요한 구간만 잘라 쓴다. `harmonizedTrack`이 만드는 배열은 항상 recentVoiceBuffer와
    // 길이가 같아서(공백은 무음으로 채움), 시작 샘플 인덱스로 자르기만 해도 그 지점부터
    // recomputing한 것과 동일한 결과가 나온다.
    @State var precomputedHarmonyTracks: [ChordGenerator.Interval: [Float]] = [:]
    // "전체 화음"/"화음만 듣기"로 나뉘어 있던 두 버튼을, 성부별로 켜고 끌 수 있는 토글 하나로
    // 일반화했다(로드맵 Phase 4, docs/CONCEPTS.md 53절) — 리드 멜로디도 다른 성부와 동등하게
    // 뮤트 대상이 된다. 기본값은 전부 켜짐(예전 "전체 화음" 버튼과 동일한 동작).
    @State var mutedVoices: Set<PlaybackVoice> = []
    let voiceClipPlayer = VoiceClipPlayer()
    // 목소리 화음 재생 시작/끝에 적용할 페이드 길이 — 녹음 구간은 원본 파형의 임의 지점에서
    // 시작/끝나서, 그대로 재생하면 클릭음이 날 수 있다(AudioGain 참고).
    let voiceClipFadeDuration: Double = 0.015
    // harmonizedTrack이 음(세그먼트)마다 거는 페이드 — 예전엔 위 voiceClipFadeDuration의
    // 1/3(~5ms)을 그대로 썼는데, 실기기 청취 피드백("멜로디음보다 박자가 늦게 들린다")의
    // 원인이 이거였다: 멜로디(recorded)는 녹음 전체 시작/끝에만 한 번 페이드가 걸리는데,
    // 화음 성부는 음 하나하나마다 매번 이 페이드를 다시 타서 모든 공격(attack)이 매번
    // 살짝 부드럽게 시작한다 — 그 미세한 지연이 음마다 누적돼 "화음이 박자보다 밀려서
    // 들린다"는 인상을 만들었다. 클릭음 방지에 필요한 최소한(2ms)까지만 줄였다 — 이보다
    // 짧으면 세그먼트 경계의 진폭 불연속이 다시 들릴 위험이 있다.
    let harmonySegmentFadeDuration: Double = 0.002

    let audioCapture = AudioCapture()
    let melodySession = MelodySession()
    let pitchSmoother = PitchSmoother()

    // 재생 중(내 목소리 화음)엔 마이크를 완전히 무시한다 — 스피커 소리가 되먹임되는 피드백
    // 루프 방지. isPlayingVoiceClip이 빠져 있던 게 26절 버그의 원인이었다.
    var isPlaybackBusy: Bool {
        isPlayingVoiceClip
    }
    @State var isPlayingVoiceClip = false

    // 카라오케 재생헤드(Phase 7) — "내 목소리로 화음" 재생이 시작된 실제 시각을 기록해두고,
    // 50ms마다 경과 시간을 melodySteps의 onsetTime/duration(원본 녹음 기준 초)과 비교해서
    // 지금 재생 중인 스텝의 인덱스를 찾는다. 새 타이밍 계산이 필요 없는 이유: PitchShifter.shift는
    // 피치만 바꾸고 길이는 그대로라, 재생 경과 시간과 원본 녹음 타임라인이 그대로 일치한다.
    @State var voiceClipPlaybackStartedAt: Date?
    @State var activePlaybackStepIndex: Int?
    // 탭으로 다른 지점을 다시 눌렀을 때(seekPlayback), 이전 재생의 onFinished 콜백이
    // voiceClipPlayer.stop() 이후에도 뒤늦게 도착해 방금 시작한 새 재생 상태를 지워버리는 걸
    // 막는 세대 토큰 — 재생을 새로 시작할 때마다 증가시키고, 콜백에서 세대가 다르면 무시한다.
    @State var playbackGeneration = 0
    // .autoconnect()로 뷰가 살아있는 동안 항상 흐르지만, updatePlaybackStepIndex()가
    // voiceClipPlaybackStartedAt이 nil이면 즉시 return하므로 재생 중이 아닐 땐 사실상 아무 일도
    // 안 한다 — 재생 시작/종료마다 타이머를 새로 만들고 해제하는 생명주기 관리보다 단순하다.
    let playheadTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    // 재생헤드가 다음 스텝으로 넘어갈 때마다 미세한 진동을 줘서(Phase 8 Task 5), 화면을 안
    // 보고 듣기만 해도 박자를 손끝으로 느낄 수 있게 한다. 마디의 첫 박(다운비트)은 더 강하게,
    // 나머지(업비트)는 약하게 — RhythmQuantizer.measureBreaks가 이미 "마디마다 음이 몇 개인지"
    // 계산해주므로, 그 구간의 시작 인덱스만 모아두면 다운비트 판정이 된다. VexFlowScoreView가
    // 악보를 그릴 때 쓰는 것과 똑같은 계산이지만, 여기선 소리(햅틱) 쪽에서만 필요해서 따로
    // 가볍게 한 번 더 돌린다(melodySteps가 바뀔 때만, 재생 중 매 tick마다가 아님).
    @State var downbeatStepIndices: Set<Int> = []
    let downbeatHaptic = UIImpactFeedbackGenerator(style: .heavy)
    let upbeatHaptic = UIImpactFeedbackGenerator(style: .light)

    // 화음이 나오는 순간(카드 2개가 한꺼번에 등장) 새로 나타난 카드로 자동 스크롤하기 위한 판정.
    // melodySession.suggestedHarmony(Optional 배열) 자체는 Equatable이 아니라서, onChange/애니메이션
    // 트리거로 쓰기 쉬운 단순 Bool로 한 번 감싼다.
    var hasHarmony: Bool { melodySession.suggestedHarmony != nil }

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
        .onChange(of: mutedVoices) { _, _ in
            scoreContentVersion += 1
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
}
