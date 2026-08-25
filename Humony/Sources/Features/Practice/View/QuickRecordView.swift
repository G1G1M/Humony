import SwiftUI

/// "빠른 녹음" 모드의 캡처 영역 — 단음/멜로디 모드처럼 프레임마다 바로 음을 확정하는 대신,
/// 노래 한 구간을 통째로 녹음한 뒤 끝나면 한 번에 분석한다. 이 뷰 자체는 상태를 갖지 않는
/// 순수 표시 컴포넌트다 — 마이크 시작/정지, `RecordingAnalyzer` 호출 같은 실제 로직은
/// `PracticeView`가 맡고, 여기선 지금 어느 단계(`Phase`)인지만 받아서 보여준다.
///
/// 대기/녹음 중 상태는 `HarmonyCard` 같은 카드 크롬 없이 화면의 주인공이 되는 "히어로"
/// 레이아웃(큰 원형 버튼+짧은 소개 문구)을 쓴다 — 이 화면이 이제 연습 탭의 기본 진입점이라,
/// 다른 실시간 피치 카드와 톤이 비슷하면 첫인상에서 존재감이 묻힌다는 판단. 분석 중/결과/에러
/// 상태는 반대로 카드형 컨테이너를 스스로 그려서(부모가 더는 감싸주지 않으므로) 결과가
/// 붕 떠 보이지 않게 한다.
struct QuickRecordView: View {
    /// 명세서(v1.0) "3단계 프로그레시브 로딩" — 빈 오선보 대신 상태 텍스트+진행률로 체감 대기
    /// 시간을 줄인다. 실제 연산 두 단계(음성 분석=`RecordingAnalyzer.analyze`, 화음 생성=
    /// `ChordGenerator.harmonizeSequence`)는 이 카드 진행률에 그대로 반영되지만, 세 번째
    /// "악보 그리는 중"(VexFlow WKWebView 렌더링)은 결과가 이미 화면에 나온 뒤 악보 카드 안
    /// 자체 스피너로 보여준다(같은 문구를 씀) — 로딩 카드 하나로 완전히 통합하려면 악보 뷰를
    /// 결과 노출 전에 미리 마운트해야 해서 화면 구조를 더 크게 손대야 한다. 지금은 실제로 걸리는
    /// 시간(수백 ms~수 초)에 비해 이 정도로도 체감 개선 효과가 충분하다고 판단해 범위를 좁혔다.
    enum AnalysisStage: Equatable {
        case voiceAnalysis
        case harmonyGeneration

        var statusText: String {
            switch self {
            case .voiceAnalysis: return "음성 분석 중"
            case .harmonyGeneration: return "화음 생성 중"
            }
        }

        var progress: Double {
            switch self {
            case .voiceAnalysis: return 0.5
            case .harmonyGeneration: return 1.0
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case recording
        case analyzing(AnalysisStage)
        case result(noteCount: Int)
        case error(String)

        /// 녹음/취소 버튼처럼 "지금 한창 처리 중이라 건드리면 안 되는" 상태 판정에 쓰는 공용 헬퍼.
        var isRecordingOrAnalyzing: Bool {
            switch self {
            case .recording, .analyzing: return true
            case .idle, .result, .error: return false
            }
        }
    }

    let phase: Phase
    let elapsed: Double
    let maxDuration: Double
    let waveformSamples: [Float]
    let onStart: () -> Void
    let onStop: () -> Void
    let onCancel: () -> Void
    let onReset: () -> Void
    // 아이패드처럼 이 뷰가 화면의 유일한 주인공으로 넓게 놓일 때 큰 화면에 맞춰 살짝 키운다 —
    // 아이폰(컴팩트 레이아웃)에서는 기존 크기를 그대로 유지해서 회귀가 없게 한다.
    var prominent: Bool = false
    // 녹음 중 실시간 음량(0~1로 정규화, `AudioCapture` 콜백에서 매 프레임 계산) — 마이크가
    // 지금 실제로 소리를 듣고 있다는 걸 헤일로 링이 목소리 크기에 맞춰 부드럽게 커지는 것으로
    // 보여준다. 파형(WaveformView)과 상호보완적: 파형은 "지금까지의 모양", 헤일로는 "지금 이 순간".
    var currentLevel: Float = 0
    // 결과/에러 카드의 인라인 "다시 녹음" 버튼 노출 여부. 아이패드 2단계 스플릿에서는 같은
    // 이름의 다른 동작(컨텍스트 유지 재녹음)을 상단 툴바가 전담해서 false로 끈다 — 나머지
    // 모든 경우(아이폰 포함)는 기본값 true로 기존 동작 그대로.
    var showsInlineRetry: Bool = true
    // 135절 — 분석중/결과/에러 상태가 스스로 그리는 글래스 카드(+패딩) 노출 여부. 아이패드
    // 2단계 스플릿의 조작부는 컬럼 전체를 이미 하나의 글래스 카드로 감싸고 있어서, 이 뷰가
    // 또 자기 카드를 그리면 패딩이 두 겹(바깥 카드 md + 이 카드 md/lg)으로 겹쳐 오른쪽 악보
    // 카드보다 콘텐츠가 훨씬 안쪽에서 시작하는 걸로 보였다(실기기 확인, 좌 49px vs 우
    // 27px) — 이미 카드로 감싸인 컨테이너 안에서만 false로 꺼서 겹침을 없앤다.
    var showsCardBackground: Bool = true

    private var heroButtonDiameter: CGFloat { prominent ? 168 : 128 }
    private var stopButtonDiameter: CGFloat { prominent ? 108 : 88 }
    private var cancelButtonDiameter: CGFloat { prominent ? 64 : 56 }
    private var waveformHeight: CGFloat { prominent ? 200 : 140 }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                idleContent
            case .recording:
                recordingContent
            case .analyzing(let stage):
                analyzingContent(stage: stage)
            case .result(let noteCount):
                resultContent(noteCount: noteCount)
            case .error(let message):
                errorContent(message: message)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 대기

    private var idleContent: some View {
        VStack(spacing: prominent ? Theme.Spacing.xl * 1.4 : Theme.Spacing.xl) {
            VStack(spacing: Theme.Spacing.sm) {
                Text("좋아하는 노래를 한 소절 불러볼까요?")
                    .font(Theme.Typography.largeTitleBold)
                    .multilineTextAlignment(.center)
                Text("노래나 허밍 모두 좋아요. 아래 버튼을 눌러 시작해 보세요.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: onStart) {
                ZStack {
                    Circle()
                        .fill(Theme.tint.opacity(0.15))
                        .frame(width: heroButtonDiameter + 36, height: heroButtonDiameter + 36)
                    Theme.glassCircle(tint: Theme.tint, diameter: heroButtonDiameter)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("녹음 시작")
        }
        .padding(.vertical, Theme.Spacing.xl)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - 녹음 중

    private var recordingContent: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ZStack(alignment: .bottomTrailing) {
                WaveformView(samples: waveformSamples)
                    .frame(height: waveformHeight)
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity)
                    // 파형이 놓이는 판 — 손으로 칠한 틴트(0.08) 대신 다른 표면들과 같은
                    // 글래스로 통일한다(iOS 26 미만에서는 예전 틴트 그대로).
                    .harmonyGlass(
                        in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous),
                        fallback: Theme.tint.opacity(0.08)
                    )

                // 135절 — 숨쉬듯 깜빡이는 REC 점을 시간 앞에 붙여, 숫자를 읽기 전에 "지금
                // 녹음 중"이라는 게 먼저 눈에 들어오게 했다(전통적인 REC 표시 관례).
                HStack(spacing: Theme.Spacing.xs) {
                    RecPulseDot()
                    Text(formattedTime(elapsed))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 4)
                .harmonyGlassCapsule()
                .padding(Theme.Spacing.sm)
            }

            ProgressView(value: min(elapsed, maxDuration), total: maxDuration)
                .tint(Theme.tint)

            // 취소/정지 두 글래스 원이 나란히 있는 묶음.
            Theme.glassGroup {
                HStack(spacing: Theme.Spacing.xl) {
                    Button(action: onCancel) {
                        ZStack {
                            Theme.glassCircle(tint: Color(uiColor: .tertiarySystemFill), diameter: cancelButtonDiameter)
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("녹음 취소")

                    Button(action: onStop) {
                        ZStack {
                            // 마이크가 지금 듣고 있는 음량에 맞춰 부드럽게 커지는 헤일로 — 값이 튈
                            // 때마다 뚝뚝 끊기지 않도록 스프링으로 감싼다(WaveformView와 같은 곡선).
                            // 조용한 구간에도 완전히 멈춰 있지 않도록 아주 약한 숨쉬기(breathing)를
                            // 겹쳐서, 음량 반응이 없을 때도 "살아있다"는 느낌을 유지한다.
                            RecordingHalo(currentLevel: currentLevel, baseDiameter: stopButtonDiameter)
                            Theme.glassCircle(tint: .red, diameter: stopButtonDiameter)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("녹음 그만")
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    private func formattedTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - 분석 중 / 결과 / 에러 — 카드 크롬을 스스로 그린다(부모가 더는 감싸주지 않으므로)

    private func analyzingContent(stage: AnalysisStage) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            Text(stage.statusText)
                .font(Theme.Typography.subheadline)
            // 정적인 ProgressView 대신 채워진 부분 위로 빛이 스윽 지나가는 shimmer — "지금
            // 진행되고 있다"는 느낌을 강조해달라는 피드백 반영(LoadingIndicators.swift 참고).
            // 진행률 자체는 AnalysisProgressBar가 단계 안에서도 계속 차오르게 담당한다(바로 아래).
            AnalysisProgressBar(stage: stage)
        }
        .frame(maxWidth: .infinity)
        .padding(showsCardBackground ? Theme.Spacing.lg : 0)
        .modifier(OptionalGlassCard(enabled: showsCardBackground))
    }

    private func resultContent(noteCount: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label("\(noteCount)개 음을 인식했어요", systemImage: "checkmark.circle.fill")
                .font(Theme.Typography.subheadlineBold)
                .foregroundStyle(Theme.pitchGood)

            if showsInlineRetry {
                Button(action: onReset) {
                    Label("다시 녹음", systemImage: "arrow.counterclockwise")
                }
                .harmonyButtonStyle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(showsCardBackground ? Theme.Spacing.md : 0)
        .modifier(OptionalGlassCard(enabled: showsCardBackground))
    }

    private func errorContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.warning)

            if showsInlineRetry {
                Button(action: onReset) {
                    Label("다시 녹음", systemImage: "arrow.counterclockwise")
                }
                .harmonyButtonStyle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(showsCardBackground ? Theme.Spacing.md : 0)
        .modifier(OptionalGlassCard(enabled: showsCardBackground))
    }
}

/// `showsCardBackground`가 false면 아무것도 안 하고 원본 뷰를 그대로 통과시킨다 — 이미 카드로
/// 감싸인 컨테이너 안에 놓일 때(아이패드 스플릿 조작부) 이중 카드가 되지 않도록 한다.
private struct OptionalGlassCard: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.harmonyGlassCard()
        } else {
            content
        }
    }
}

/// 135절 — 녹음 중 타이머 배지 앞에 붙는 숨쉬듯 깜빡이는 빨간 점. 카메라 앱들의 "REC" 표시
/// 관례를 그대로 빌려와서, 숫자를 읽기 전에 "지금 녹음되고 있다"는 걸 먼저 알아챌 수 있게 한다.
private struct RecPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 7, height: 7)
            .opacity(reduceMotion ? 1.0 : (isPulsing ? 1.0 : 0.35))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

/// 135절 — 정지 버튼 뒤 헤일로. 예전엔 `currentLevel`(실시간 음량)에만 반응해서, 음량이 낮은
/// 구간(숨 고르기, 조용한 소절)에는 완전히 멈춘 것처럼 보였다 — 음량 반응(스프링으로 부드럽게)
/// 위에 아주 약한 숨쉬기(breathing, ±3.5% 스케일)를 겹쳐서 조용할 때도 "지금 살아있다"는
/// 느낌을 유지한다. 두 애니메이션은 서로 다른 속성(frame 크기 vs scaleEffect)에 걸려 있어
/// 독립적으로 동작한다.
private struct RecordingHalo: View {
    let currentLevel: Float
    let baseDiameter: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    private var levelDiameter: CGFloat {
        baseDiameter + 20 + CGFloat(currentLevel) * 44
    }

    var body: some View {
        Circle()
            .fill(Color.red.opacity(0.16 + Double(currentLevel) * 0.22))
            .frame(width: levelDiameter, height: levelDiameter)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: currentLevel)
            .scaleEffect(reduceMotion ? 1.0 : (isBreathing ? 1.035 : 1.0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    isBreathing = true
                }
            }
    }
}

/// "완벽하게 로딩이 되다가 진짜 다 되면 딱 끝나는" 진행률 바를 만들기 위한 래퍼 — 실제
/// 진행률을 모르는 `.voiceAnalysis` 단계 동안 `ShimmerProgressBar`가 그 단계의 상한(50%)에
/// 딱 멈춰 서 있지 않고, 그 상한 바로 아래까지 스스로 천천히 계속 차오르게 한다. 예전엔
/// 단계가 바뀔 때만 값이 점프해서, 실제 분석이 오래 걸리는 녹음일수록 "50%에서 멈춰있는
/// 것처럼" 보였다("완벽하게 로딩이 되다가"라는 재현 피드백의 원인) — 실제 분석이 더 빨리
/// 끝나면 이 채워가는 애니메이션은 그냥 중간에 잘리고 다음 단계로 넘어갈 뿐이라 안전하다.
private struct AnalysisProgressBar: View {
    let stage: QuickRecordView.AnalysisStage
    @State private var displayedProgress: Double = 0.05

    var body: some View {
        ShimmerProgressBar(progress: displayedProgress)
            .onAppear { animate(to: stage) }
            .onChange(of: stage) { _, newStage in animate(to: newStage) }
    }

    private func animate(to stage: QuickRecordView.AnalysisStage) {
        switch stage {
        case .voiceAnalysis:
            // 상한(0.5)에 딱 닿지 않게(0.48까지만) 남겨둔다 — 진짜 그 단계가 끝나는
            // 순간(harmonyGeneration으로 전환)에만 상한을 딱 채우는 확실한 완료감을 주기 위해서다.
            displayedProgress = 0.05
            withAnimation(.easeOut(duration: 4.0)) {
                displayedProgress = 0.48
            }
        case .harmonyGeneration:
            withAnimation(.easeInOut(duration: 0.3)) {
                displayedProgress = 1.0
            }
        }
    }
}
