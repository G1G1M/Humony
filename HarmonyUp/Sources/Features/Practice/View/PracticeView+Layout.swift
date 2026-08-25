import SwiftUI
import UIKit

/// `PracticeView`의 화면 레이아웃(컴팩트/레귤러 두 갈래)과, 두 레이아웃이 공유하는 캡처
/// 영역·악보 카드 UI. 상태 선언과 `body`는 `PracticeView.swift`, 녹음 캡처 책임은
/// `PracticeView+Capture.swift`에 있다. 채점(`PracticeView+Scoring.swift`, `scoringCard`)은
/// 116절에 화음 API를 걷어내며 화면에서 뺐다가, 화음이 다시 자리잡은 뒤 136절에 새 흐름
/// (성부를 먼저 들어보고 → 소리를 끄고 → 한 소절을 통째로 불러 배치 채점)으로 되붙였다 —
/// `captureHero` 안, 재생 조작부 바로 아래에 있다.
extension PracticeView {
    var compactLayout: some View {
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
                                .transition(cardAppearTransition)
                        }
                    }
                    .padding()
                    // 카드가 새로 생기거나 사라질 때 위 .transition이 실제로 애니메이션되게 한다 —
                    // 이 modifier가 없으면 SwiftUI가 즉시(애니메이션 없이) 나타나고 사라진다.
                    .animation(.easeOut(duration: 0.3), value: hasCapturedNote)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                // 카드가 막 나타난 시점에 화면 아래로 스크롤해서, "방금 뭐가 생겼다"는 걸
                // 사용자가 놓치지 않고 바로 보게 한다.
                .onChange(of: hasCapturedNote) { _, appeared in
                    guard appeared else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo("sheetMusicCard", anchor: .top)
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

    var regularLayout: some View {
        NavigationStack {
            Group {
                if hasCapturedNote {
                    regularSplitStage
                } else {
                    regularHeroStage
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
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
                            // 새로 부르기: 세션 컨텍스트(악보/믹서/채점 기록)는 그대로 두고 마이크만
                            // 즉시 재가동한다 — startQuickRecording()이 hasCapturedNote/melodySteps를
                            // 건드리지 않아서, 새 분석이 끝나야(applyQuickRecordResult) 우측 악보가
                            // 그때 가서 자연스럽게 갱신된다("홈으로"의 완전 리셋과 다른 지점). 라벨을
                            // QuickRecordView의 인라인 "다시 녹음"(완전 리셋)과 일부러 다르게 지어서
                            // — 같은 문구가 기기/레이아웃에 따라 다른 동작을 하던 걸 구분함(크리틱 P2).
                            startQuickRecording()
                        } label: {
                            Label("새로 부르기", systemImage: "arrow.counterclockwise")
                        }
                        .disabled(quickRecordPhase.isRecordingOrAnalyzing)
                    }
                    // 명세서(v1.0) "퀵 스왑" — 조작부/악보부 좌우 위치를 즉시 전환. 왼손잡이나
                    // DAW(조작부가 늘 한쪽에 고정된 환경) 사용자 습관에 맞출 수 있게.
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isControlPanelLeading.toggle()
                            }
                        } label: {
                            Label("조작부·악보 위치 바꾸기", systemImage: "rectangle.2.swap")
                        }
                    }
                }
            }
        }
    }

    /// 1단계 — 아직 아무것도 캡처하기 전. 다른 패널 없이 화면 중앙에 큰 히어로 버튼+파형만 둬서
    /// "여기서 시작하면 된다"는 게 한눈에 보이게 한다(컴팩트 레이아웃의 카드형과 달리, 넓은
    /// 화면을 살려 더 크게).
    var regularHeroStage: some View {
        VStack {
            Spacer()
            captureHero(prominent: true)
                .frame(maxWidth: 560)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    /// 2단계 — 조작부(녹음 상태+내 목소리로 화음+채점)/악보부(상시 큼) 두 열. 명세서(v1.0)
    /// "2단 분할 반응형 레이아웃"에 맞춰 6:4(악보:조작) 비율로 나누고, 헤더의 스왑 버튼
    /// (`isControlPanelLeading`)으로 좌우를 즉시 바꿀 수 있다. 두 열이 각자 독립된 컨테이너라
    /// (조작부는 자체 `ScrollView`, 악보부는 `sheetMusicPanel`이 내부에서 스크롤) 한쪽을
    /// 스크롤해도 다른 쪽은 그대로 고정돼 있다 — 명세서의 "독립 스크롤"은 이 구조 자체로
    /// 이미 충족된다.
    var regularSplitStage: some View {
        GeometryReader { geo in
            // 조작부 폭은 전체의 40%를 기본으로 하되, 아이폰 카드 폭(380, 컴팩트 레이아웃과
            // 동일)보다 너무 좁아지거나(작은 Split View) 너무 넓어지지(초대형 아이패드 가로)
            // 않게 300~480 범위로 clamp한다 — 명세서 6:4 비율의 의도(조작 영역이 항상 쓰기
            // 편한 폭)를 다양한 실제 화면 크기에서도 지키기 위한 안전장치.
            let controlWidth = min(480, max(300, geo.size.width * 0.4))

            // 조작부/악보부 두 큰 글래스 판이 나란히 놓이는 자리 — 화면에서 가장 넓은 글래스 면적이라
            // 컨테이너로 묶는 이득(샘플링 합치기)이 가장 크다.
            Theme.glassGroup {
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    if isControlPanelLeading {
                        controlColumn
                            .frame(width: controlWidth)
                        Divider()
                        scoreColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        scoreColumn
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        controlColumn
                            .frame(width: controlWidth)
                    }
                }
            }
            // 135절 — 좌우 여백을 컬럼 사이 간격(Theme.Spacing.lg)과 같은 값으로 맞췄다. 예전엔
            // 기본 .padding()(시스템 기본값)을 썼는데, 툴바("홈으로"/"새로 부르기"/스왑) 버튼의
            // 좌우 정렬선과 아래 두 컬럼의 좌우 정렬선이 안 맞아 보인다는 지적 — 툴바는 앱 전체
            // 화면에서 값을 직접 조절할 수 없는 시스템 여백을 쓰므로, 대신 본문 쪽 여백을 이미
            // 쓰고 있던 디자인 토큰(lg=24)으로 통일해 적어도 본문 안에서는 일관된 격자가
            // 되도록 했다.
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
    }

    /// 조작부 — 지금은 캡처만. 스왑 시에도 내용은 그대로, 위치만 바뀐다.
    ///
    /// **135절, 악보 카드와 높이·색 맞추기**: 예전엔 이 컬럼이 내용 높이만큼만 차지해서
    /// 오른쪽 악보 카드(글래스, `maxHeight: .infinity`)보다 짧게 끝나고 그 아래는 배경색
    /// 그대로 비어 보였다 — 두 컬럼이 나란히 있는데 높이도 색도 안 맞아 어색했다는 지적.
    /// 컬럼 전체를 악보 카드와 같은 `harmonyGlassCard()`로 감싸고 남은 높이까지 꽉 채워서
    /// 두 컬럼이 같은 색·같은 높이의 블록으로 짝을 이루게 했다.
    private var controlColumn: some View {
        // ScrollView에 harmonyGlassCard()를 바로 붙이면 글래스 배경이 스크롤 "뷰포트"가 아니라
        // 스크롤 "콘텐츠" 크기에 맞춰 그려져서, 콘텐츠가 짧을 땐 카드가 컬럼 상단에만 작게
        // 그려지고 나머지는 배경색 그대로 비어 보이는 문제가 있었다(실기기 확인) — ScrollView를
        // VStack으로 한 겹 감싸고, 그 VStack에 프레임+글래스 카드를 적용해서 실제로 배정된
        // 전체 높이만큼 카드가 그려지게 했다.
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    // showsInlineRetry: false — "다시 녹음"은 이제 툴바가 전담한다. 이 카드
                    // 안에도 같은 이름의 버튼을 남겨두면 툴바 버전과 의미가 갈려서(하나는
                    // 컨텍스트 유지, 하나는 완전 리셋) 헷갈린다.
                    // showsCardBackground: false — 이 컬럼 전체가 이미 카드(아래 harmonyGlassCard())라
                    // QuickRecordView가 또 자기 카드를 그리면 패딩이 겹쳐 오른쪽 악보 카드보다
                    // 콘텐츠가 안쪽에서 시작하는 것처럼 보인다(135절).
                    captureHero(prominent: false, showsInlineRetry: false, showsCardBackground: false)
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .harmonyGlassCard()
    }

    /// "다시 녹음" 중(악보부는 새 분석이 끝날 때까지 대기 상태)이면 진행 표시를, 아니면
    /// 실제 악보를 보여준다 — 이전 녹음의 악보를 그대로 둔 채 새로 녹음하면 "지금 보이는 게
    /// 방금 부른 거냐, 예전 거냐" 헷갈릴 수 있어서 명확히 구분했다.
    @ViewBuilder
    var scoreColumn: some View {
        if quickRecordPhase.isRecordingOrAnalyzing {
            sheetMusicRerecordingPlaceholder
        } else {
            sheetMusicPanel(fillAvailable: true)
        }
    }

    var isReanalyzing: Bool {
        if case .analyzing = quickRecordPhase { return true }
        return false
    }

    var sheetMusicRerecordingPlaceholder: some View {
        PulsingLoadingLabel(message: isReanalyzing ? "새로 부른 노래를 분석하는 중이에요" : "다시 녹음하는 중이에요")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 128절 — 성부별 솔로 버튼이 순회할 목록.
    //
    // 순서는 `ChordGenerator.Interval.displayOrder`(악보와 같은 음높이 내림차순)를 따른다 —
    // 예전엔 여기만 "낮은 음부터"(멜로디/베이스/3도/5도)라 악보와 정반대였고, "멜로디 바로
    // 아래"가 화면마다 다른 성부를 가리켰다.
    var soloVoiceOptions: [(label: String, voice: VoiceHarmonyTrackBuilder.Voice)] {
        [(label: "멜로디", voice: .melody)]
            + ChordGenerator.Interval.displayOrder.map {
                (label: $0.koreanLabel, voice: .harmony($0))
            }
    }

    // MARK: - 두 레이아웃이 공유하는 섹션

    /// 마이크 권한이 꺼져 있을 때 캡처 영역 자리에 보여주는 전용 상태 — "왜 안 되는지" 설명하고
    /// 바로 설정 앱의 이 앱 권한 화면으로 이동할 수 있게 한다.
    @ViewBuilder
    var micPermissionDeniedContent: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("마이크 권한이 꺼져 있어요", systemImage: "mic.slash.fill")
                .font(Theme.Typography.subheadlineBold)
                .foregroundStyle(Theme.warning)
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

    /// 캡처 영역 — 여기서부터 흐름이 시작된다. 빠른 녹음이 연습의 유일한 진입점이라 카드
    /// 크롬(제목바/테두리) 없이 화면의 주인공이 되는 히어로 레이아웃을 쓴다(QuickRecordView가
    /// 스스로 대기/녹음 중 상태를 꾸민다).
    /// - Parameters:
    ///   - prominent: 아이패드 1단계 대기 화면처럼 이 뷰가 화면의 유일한 주인공일 때 크게.
    ///   - showsInlineRetry: 결과/에러 상태의 "다시 녹음" 인라인 버튼 노출 여부(기본 true, 아이폰은
    ///     항상 유지). 아이패드 2단계에서만 false로 꺼서 툴바의 "다시 녹음"과 의미가 안 겹치게 한다.
    ///   - showsCardBackground: 결과/에러/분석중 상태가 스스로 카드 배경을 그릴지(기본 true).
    ///     아이패드 2단계 조작부(`controlColumn`)처럼 바깥에서 이미 카드로 감싸는 컨테이너
    ///     안에서만 false로 꺼서 카드가 두 겹으로 겹치지 않게 한다(135절).
    @ViewBuilder
    func captureHero(prominent: Bool, showsInlineRetry: Bool = true, showsCardBackground: Bool = true) -> some View {
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
                    showsInlineRetry: showsInlineRetry,
                    showsCardBackground: showsCardBackground
                )

                // 녹음 버튼 아래에 작게 — 녹음이 시작되면(또는 이미 결과/에러 상태면) 참고음은
                // 더 이상 의미가 없어서 대기 상태(.idle)일 때만 보여준다.
                if quickRecordPhase == .idle {
                    startingNoteControls
                }

                // 128절 — "재생 버튼들이 악보 카드 안에 있었는데, 악보 말고 반대편(조작부)에
                // 만들어달라"는 요청 — 원본/화음 듣기/내 목소리로 화음/성부별 솔로/뮤트 토글을
                // 전부 여기(악보와 분리된 조작부)로 옮겼다.
                if !recentVoiceBuffer.isEmpty {
                    // 158절 — 녹음 뒤를 두 단계로 끊는다: ② 악보 비교(관문) → ③ 화음 결과.
                    // 화음은 이미 계산돼 있고, 여기서 정하는 건 무엇을 보여줄지뿐이다.
                    switch resultStage {
                    case .reviewingScore:
                        scoreReviewSection

                    case .harmony:
                        backToScoreReviewRow

                        playbackControls

                        // 136절 — 채점을 다시 붙였다. 화음을 들어본 바로 아래에 이어서 두는 이유:
                        // "먼저 들어보고 → 그 성부를 따라 부른다"는 흐름이 위아래로 자연스럽게 읽힌다.
                        Divider()
                            .padding(.vertical, Theme.Spacing.xs)
                        scoringCard
                    }
                }
            }
        }
    }

    /// 원본 재생/화음 재생(목소리)/성부별 솔로/뮤트 토글을 모아둔 조작부 전용 섹션.
    /// 예전엔 `sheetMusicPanel`(악보 카드) 안에 있었는데, 재생은 "조작"이지 악보의 일부가
    /// 아니라는 지적으로 여기(캡처 영역과 같은 카드)로 옮겼다(128절).
    ///
    /// **135절, 재생 버튼 하나+성부별 목록으로 재설계**: 예전엔 재생 방식(원본/합성음 화음/
    /// 목소리 화음)마다 버튼이 따로 있고 성부별 솔로 4개+뮤트 4개까지 항상 펼쳐져 있어 버튼이
    /// 최대 11개까지 쌓였다(정보 밀도 지적). 135절에서 우선 세그먼트(원본/내 목소리) 방식으로
    /// 압축했었지만, **135절에서 "원본"까지 없애고 "내 목소리" 하나로 더 합쳤다** — 화음은
    /// 이미 "내 목소리"로 다 들을 수 있어 원본 재생이 굳이 따로 있을 이유가 없다는 판단(원본
    /// 전용 재생 로직도 함께 제거). 성부별 솔로/뮤트도 접어뒀던 디스클로저를 없애고 **항상
    /// 펼쳐서** 보여준다 — "열었다 닫았다 하지 말고 처음부터 보이게" 요청.
    var playbackControls: some View {
        // 재생 버튼들(목소리 화음/성부별 솔로)은 항상 하나만 켜지게 서로 막는다 — 동시에 여러
        // 개가 스피커로 나가면 마이크 피드백 가드(isPlayingVoiceHarmony 등) 판단이 꼬이기 쉽다.
        let anyPlaybackActive = isPlayingVoiceHarmony || playingSoloVoice != nil

        // 재생 버튼 1개 + 성부 4행 × 2개 = 글래스 표면이 최대 9장 겹치는 자리라, 낱개로 두지 않고
        // 네이티브 컨테이너로 묶는다(Theme.glassGroup 주석 참고 — 서로 섞이게 하고 샘플링 비용도 합친다).
        return Theme.glassGroup {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Button {
                    toggleVoiceHarmonyPlayback()
                } label: {
                    // 화음 트랙을 만드는 동안(WORLD 분석+재합성) 무슨 일이 일어나는지 알린다 —
                    // 예전엔 이 계산이 메인 스레드에서 동기로 돌아 화면이 통째로 멈췄고, 지금은
                    // 백그라운드로 옮겼지만 소리가 나기까지 시간이 걸리는 건 그대로다. 아무 표시가
                    // 없으면 "눌렸나?" 싶어 다시 누르게 된다.
                    HStack(spacing: Theme.Spacing.xs) {
                        if isPreparingHarmony {
                            ProgressView().controlSize(.small)
                            Text("화음 만드는 중이에요")
                        } else {
                            Image(systemName: isPlayingVoiceHarmony ? "stop.fill" : "play.fill")
                            Text(isPlayingVoiceHarmony ? "정지" : "내 목소리로 화음 듣기")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .harmonyButtonStyle(prominent: true)
                .disabled(isPreparingHarmony || (anyPlaybackActive && !isPlayingVoiceHarmony))

                Label("성부별로 듣기", systemImage: "waveform")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, Theme.Spacing.xs)

                // 128절 — 멜로디/베이스/3도/5도를 각각 따로 들어보는 성부별 솔로+뮤트.
                VStack(spacing: 0) {
                    ForEach(Array(soloVoiceOptions.enumerated()), id: \.element.label) { index, option in
                        voiceRow(option: option, anyPlaybackActive: anyPlaybackActive || isPreparingHarmony)
                        if index < soloVoiceOptions.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    /// 성부 하나(멜로디/베이스/3도/5도)의 솔로 재생+뮤트 토글 한 줄. 베이스/3도/5도는
    /// `Theme.intervalColor`로 라벨을 물들여, 채점이 다시 붙었을 때 HistoryView 정확도
    /// 차트와 같은 색으로 이어지게 한다(135절).
    private func voiceRow(option: (label: String, voice: VoiceHarmonyTrackBuilder.Voice), anyPlaybackActive: Bool) -> some View {
        let isMuted = mutedVoices.contains(option.voice)
        let isSoloPlaying = playingSoloVoice == option.voice
        let labelColor: Color = {
            if case .harmony(let interval) = option.voice { return Theme.intervalColor(for: interval) }
            return .primary
        }()

        return HStack(spacing: Theme.Spacing.sm) {
            Text(option.label)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(labelColor)

            Spacer()

            Button {
                toggleVoiceSolo(option.voice)
            } label: {
                Image(systemName: isSoloPlaying ? "stop.fill" : "play.fill")
            }
            .harmonyButtonStyle()
            .controlSize(.small)
            .frame(minWidth: 44, minHeight: 44)
            .disabled(anyPlaybackActive && !isSoloPlaying)
            .accessibilityLabel(isSoloPlaying ? "\(option.label) 정지" : "\(option.label) 솔로 재생")

            Button {
                toggleMute(option.voice)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .harmonyButtonStyle()
            .controlSize(.small)
            .frame(minWidth: 44, minHeight: 44)
            .opacity(isMuted ? 0.5 : 1.0)
            .accessibilityLabel(isMuted ? "\(option.label) 음소거됨" : "\(option.label) 켜짐")
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// 녹음 전 참고음(첫음)을 골라 들어보는 작은 컨트롤 — 드롭다운(Picker)으로 C3~C6 범위에서
    /// 반음 단위로 고르고(예전 Stepper 범위와 동일, 47절), 재생 버튼을 누르면 그 음을 계속
    /// 재생해서 무반주로 노래를 시작할 때 음정을 잡을 수 있게 한다. 녹음 버튼보다 시선을 끌면
    /// 안 되는 보조 기능이라 카드 배경 없이 작게 둔다. `TonePlayer`는 자체 오디오 엔진이라
    /// 아직 마이크가 켜지기 전(대기 상태)에만 노출되므로 되먹임 걱정이 없다.
    var startingNoteControls: some View {
        VStack(spacing: Theme.Spacing.xs) {
            // 컨트롤만 두면 "🎼 C4 ▶"가 무슨 기능인지 알 수가 없다 — 기능 이름("첫 음 듣기")만
            // 적는 대신 **왜 필요한지**를 앞에 둔다. 반주 없이 부른다는 사실을 사용자가 스스로
            // 알아채야 손이 가기 때문이다. 마이크 버튼(화면의 주인공)과 시선을 다투면 안 되는
            // 보조 기능이라 caption+secondary로 가장 가볍게 둔다.
            Text("반주가 없으니, 첫 음만 듣고 시작해 보세요")
                .font(Theme.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // 음 선택 메뉴와 재생 버튼이 나란히 붙어 있는 작은 묶음 — 둘 다 글래스라 컨테이너로 묶는다.
            Theme.glassGroup {
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
                        .font(Theme.Typography.caption)
                    }
                    .harmonyButtonStyle()
                    .controlSize(.small)
                    // controlSize(.small)만으로는 실제 탭 영역이 HIG 최소 44×44pt보다 작아질 수 있어서
                    // (크리틱 P2) — 시각적 크기(작은 알약)는 그대로 두고 탭 영역만 프레임으로 넓힌다.
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("첫 음 선택")

                    Button {
                        toggleStartingNotePlayback()
                    } label: {
                        Image(systemName: isPlayingStartingNote ? "stop.fill" : "play.fill")
                            .font(Theme.Typography.caption)
                    }
                    .harmonyButtonStyle()
                    .controlSize(.small)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(isPlayingStartingNote ? "첫 음 재생 정지" : "첫 음 듣기")
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    func toggleStartingNotePlayback() {
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
            statusText = "첫 음 재생 실패: \(error.localizedDescription)"
        }
    }

    /// 악보(VexFlow 오선보) 카드. `fillAvailable`이 true면(아이패드 오른쪽 패널) 고정 높이
    /// 대신 남은 공간을 꽉 채우고, 이미 상시 크게 보이니 "전체화면으로 크게 보기" 버튼은 뺀다
    /// (그 버튼은 컴팩트 레이아웃에서 좁은 카드 안에 갇힌 악보를 크게 보기 위한 것이었다).
    func sheetMusicPanel(fillAvailable: Bool) -> some View {
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

                // 158절 — 같은 자리에 두 줄이 그려질 때는 무엇이 무엇인지 알려줘야 한다.
                if resultStage == .reviewingScore, scoreComparisonPayloadJSON != nil {
                    Label("위: 부른 대로 · 아래: 악보에 맞춘 뒤", systemImage: "arrow.up.arrow.down")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.tint)
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
    var scoreViewWithLoadingOverlay: some View {
        ZStack {
            // 158절 — 비교 단계에서는 같은 자리에 "부른 대로 / 교정 후" 두 줄을 그린다.
            // 재생 하이라이트가 필요 없는 정적 악보라 PlaybackHighlightingScoreView를 거치지 않는다.
            if resultStage == .reviewingScore, let comparisonJSON = scoreComparisonPayloadJSON {
                VexFlowScoreView(
                    steps: melodySteps,
                    activeStepIndex: nil,
                    onSeekToStep: { _ in },
                    isRendering: $isScoreRendering,
                    contentVersion: scoreContentVersion,
                    payloadJSON: comparisonJSON
                )
            } else {
                PlaybackHighlightingScoreView(
                    steps: melodySteps,
                    contentVersion: scoreContentVersion,
                    isRendering: $isScoreRendering,
                    currentPlaybackTime: currentPlaybackTime
                )
            }
            if isScoreRendering {
                PulsingLoadingLabel(message: "악보를 만드는 중이에요")
            }
        }
    }
}
