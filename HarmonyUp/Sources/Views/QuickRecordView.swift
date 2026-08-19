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
                    .background(
                        Theme.tint.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius, style: .continuous)
                    )

                Text(formattedTime(elapsed))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(Theme.Spacing.sm)
            }

            ProgressView(value: min(elapsed, maxDuration), total: maxDuration)
                .tint(Theme.tint)

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
                        // 마이크가 지금 듣고 있는 음량에 맞춰 부드럽게 커지는 헤일로 — 값이 튈 때마다
                        // 뚝뚝 끊기지 않도록 짧은 애니메이션을 건다(WaveformView의 0.08초 관례와 동일).
                        Circle()
                            .fill(Color.red.opacity(0.16 + Double(currentLevel) * 0.22))
                            .frame(
                                width: stopButtonDiameter + 20 + CGFloat(currentLevel) * 44,
                                height: stopButtonDiameter + 20 + CGFloat(currentLevel) * 44
                            )
                            .animation(.easeOut(duration: 0.08), value: currentLevel)
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
            ProgressView(value: stage.progress)
                .tint(Theme.tint)
                .animation(.easeInOut(duration: 0.3), value: stage.progress)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.lg)
        .harmonyGlassCard()
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
        .padding(Theme.Spacing.md)
        .harmonyGlassCard()
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
        .padding(Theme.Spacing.md)
        .harmonyGlassCard()
    }
}
