import SwiftUI

/// "빠른 녹음" 모드의 캡처 카드 내용 — 단음/멜로디 모드처럼 프레임마다 바로 음을 확정하는 대신,
/// 노래 한 구간을 통째로 녹음한 뒤 끝나면 한 번에 분석한다. 이 뷰 자체는 상태를 갖지 않는
/// 순수 표시 컴포넌트다 — 마이크 시작/정지, `RecordingAnalyzer` 호출 같은 실제 로직은
/// `PracticeView`가 맡고, 여기선 지금 어느 단계(`Phase`)인지만 받아서 보여준다.
struct QuickRecordView: View {
    enum Phase: Equatable {
        case idle
        case recording
        case analyzing
        case result(noteCount: Int)
        case error(String)
    }

    let phase: Phase
    let elapsed: Double
    let maxDuration: Double
    let waveformSamples: [Float]
    let onStart: () -> Void
    let onStop: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            switch phase {
            case .idle:
                Button(action: onStart) {
                    Label("녹음 시작", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)

                Text("버튼을 누르고 노래나 허밍을 최대 \(Int(maxDuration))초까지 불러주세요")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

            case .recording:
                Button(action: onStop) {
                    Label("녹음 그만", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                WaveformView(samples: waveformSamples)
                    .frame(height: 88)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .frame(maxWidth: .infinity)
                    .background(
                        Theme.tint.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: Theme.cardCornerRadius - 4, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(elapsed, maxDuration), total: maxDuration)
                    Text(String(format: "%.0f초 / 최대 %.0f초", min(elapsed, maxDuration), maxDuration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

            case .analyzing:
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                    Text("녹음을 분석하는 중…")
                        .font(Theme.Typography.subheadline)
                }

            case .result(let noteCount):
                Label("\(noteCount)개 음을 인식했어요", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.subheadlineBold)
                    .foregroundStyle(Theme.pitchGood)

                Button(action: onReset) {
                    Label("다시 녹음", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)

            case .error(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.orange)

                Button(action: onReset) {
                    Label("다시 녹음", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
