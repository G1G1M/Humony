import SwiftUI
import UIKit

/// `PracticeView`의 화면 레이아웃(컴팩트/레귤러 두 갈래)과, 두 레이아웃이 공유하는 캡처
/// 영역·악보 카드 UI. 상태 선언과 `body`는 `PracticeView.swift`, 나머지 책임(내 목소리로
/// 화음 재생/채점/녹음 캡처)은 각각 `PracticeView+VoiceHarmony.swift`/
/// `PracticeView+Scoring.swift`/`PracticeView+Capture.swift`에 있다.
extension PracticeView {
    var compactLayout: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        captureHero(prominent: false)
                            .id("captureCard")

                        // 카드 순서: 캡처 다음 바로 "내 목소리로 화음"이 오도록 악보보다 앞에
                        // 둔다 — PRODUCT.md 핵심 가치("내 목소리로 화음 듣기"가 채점보다도
                        // 우선인 이 앱의 대표 경험)에 맞춰, 악보(이론/표기 중심이라 상대적으로
                        // 보조적)를 지나치지 않고 바로 그 경험에 닿게 한다. 화음이 나오기 전엔
                        // 안 보인다(할 게 없으므로) — hasCapturedNote가 참이어도 온음계 밖
                        // 음뿐이면 harmony가 없을 수 있는데(드문 경우), 그때는 이 카드가 아예
                        // 안 보이고 악보만 보인다.
                        if melodySession.suggestedHarmony != nil {
                            voiceHarmonyPanel
                                .id("voiceHarmonyCard")
                                .transition(cardAppearTransition)
                        }

                        // 악보(VexFlow 오선보) — 첫 녹음 분석이 끝나기 전엔 보여줄 게 없다.
                        if hasCapturedNote {
                            sheetMusicPanel(fillAvailable: false)
                                .id("sheetMusicCard")
                                .transition(cardAppearTransition)
                        }

                        if melodySession.suggestedHarmony != nil {
                            scoringCard
                                .transition(cardAppearTransition)
                        }
                    }
                    .padding()
                    // 카드가 새로 생기거나 사라질 때 위 .transition이 실제로 애니메이션되게 한다 —
                    // 이 modifier가 없으면 SwiftUI가 즉시(애니메이션 없이) 나타나고 사라진다.
                    .animation(.easeOut(duration: 0.3), value: hasCapturedNote)
                    .animation(.easeOut(duration: 0.3), value: hasHarmony)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                // 카드가 막 나타난 시점에 화면 아래로 스크롤해서, "방금 뭐가 생겼다"는 걸
                // 사용자가 놓치지 않고 바로 보게 한다. hasCapturedNote와 hasHarmony는 거의
                // 항상 같은 순간에 함께 true가 되므로(applyQuickRecordResult가 한 번에 둘 다
                // 채움), 스크롤 목표는 hasHarmony 하나로 충분하다 — 예전엔 hasCapturedNote용
                // 스크롤도 따로 있었는데 "조성과 화음" 카드 제거(54절) 이후 존재하지 않는
                // id("keyHarmonyCard")를 가리키는 죽은 코드로 남아 있었다(조용히 아무 일도 안
                // 하는 버그, 이번에 발견해서 정리함).
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
            .padding()
        }
    }

    /// 조작부 — 캡처+내 목소리로 화음+채점. 스왑 시에도 내용은 그대로, 위치만 바뀐다.
    private var controlColumn: some View {
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
        VStack(spacing: Theme.Spacing.sm) {
            ProgressView()
            Text(isReanalyzing ? "새로 부른 노래를 분석하는 중이에요" : "다시 녹음하는 중이에요")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @ViewBuilder
    func captureHero(prominent: Bool, showsInlineRetry: Bool = true) -> some View {
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
    var startingNoteControls: some View {
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
            .accessibilityLabel("첫음 선택")

            Button {
                toggleStartingNotePlayback()
            } label: {
                Image(systemName: isPlayingStartingNote ? "stop.fill" : "play.fill")
                    .font(Theme.Typography.caption)
            }
            .harmonyButtonStyle()
            .controlSize(.small)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(isPlayingStartingNote ? "첫음 재생 정지" : "첫음 듣기")
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
            statusText = "첫음 재생 실패: \(error.localizedDescription)"
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
}
