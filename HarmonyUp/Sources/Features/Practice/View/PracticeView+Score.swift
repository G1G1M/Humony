import SwiftUI
import UniformTypeIdentifiers

/// 부른 뒤 악보를 붙여 채보를 대조·교정하는 흐름 (155절).
///
/// **왜 녹음 전이 아니라 녹음 뒤에 붙이는가**(사용자 결정): 녹음 화면에서 준비할 게 늘어나지
/// 않고, 이미 부른 소리를 그대로 둔 채 악보를 바꿔가며 비교해볼 수 있다. 원본 목소리
/// (`recentVoiceBuffer`)를 계속 들고 있기 때문에 악보를 붙이면 **다시 부르지 않고 재분석**만
/// 하면 된다.
extension PracticeView {

    /// 받아들이는 악보 형식. PDF는 아직이다 — 스캔본이면 딥러닝 OMR이 필요해 온디바이스
    /// 원칙과 부딪힌다. MuseScore 같은 무료 툴로 PDF → MusicXML 변환이 가능하다.
    static var scoreContentTypes: [UTType] {
        [UTType(filenameExtension: "musicxml"), UTType.xml, UTType.midi]
            .compactMap { $0 }
    }

    /// 결과 상태에서 조작부에 붙는 "악보와 대조" 카드.
    @ViewBuilder
    var scoreReferenceCard: some View {
        Theme.glassGroup {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label("악보와 대조", systemImage: "doc.text.magnifyingglass")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.secondary)

                if let name = importedScoreName {
                    Text(name)
                        .font(Theme.Typography.body)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let comparison = scoreComparison {
                        Text(ScoreComparisonSummary.text(for: comparison))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(comparison.isApplied ? .secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: Theme.Spacing.sm) {
                        Button("다른 악보") { isImportingScore = true }
                            .harmonyButtonStyle(prominent: false)
                        Button("떼기") { detachScore() }
                            .harmonyButtonStyle(prominent: false)
                    }
                    .disabled(quickRecordPhase.isRecordingOrAnalyzing)
                } else {
                    Text("악보를 붙이면 부른 음을 악보에 맞춰 다듬어요")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        isImportingScore = true
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "paperclip")
                            Text("악보 붙이기")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .harmonyButtonStyle(prominent: false)
                    .disabled(quickRecordPhase.isRecordingOrAnalyzing)
                }

                if let message = scoreImportMessage {
                    Text(message)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("악보와 대조")
    }

    // MARK: - 동작

    func handleScoreImport(_ result: Result<URL, Error>) {
        scoreImportMessage = nil

        switch result {
        case let .success(url):
            // 파일 앱/아이클라우드에서 고른 파일은 샌드박스 밖이라 접근 권한을 열어야 읽힌다.
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            do {
                importedScore = try ScoreImporter.load(from: url)
                importedScoreName = url.lastPathComponent
                reanalyzeWithCurrentScore()
            } catch {
                // 사용자에게는 무엇을 하면 되는지를 말한다 — 원인 코드가 아니라(UI 크리틱 P1).
                importedScore = nil
                importedScoreName = nil
                scoreImportMessage = Self.importErrorMessage(error)
            }

        case let .failure(error):
            scoreImportMessage = "악보를 열지 못했어요 — \(error.localizedDescription)"
        }
    }

    static func importErrorMessage(_ error: Error) -> String {
        guard let importError = error as? ScoreImporter.ImportError else {
            return "악보를 읽지 못했어요 — 다른 파일로 시도해주세요"
        }
        switch importError {
        case .unsupportedFileType:
            return "MusicXML(.musicxml/.xml)이나 MIDI(.mid) 파일이 필요해요 — PDF는 MuseScore 같은 무료 툴로 MusicXML로 바꿔주세요"
        case .malformed:
            return "악보 파일이 깨진 것 같아요 — 다른 파일로 시도해주세요"
        case .noNotesFound:
            return "악보에서 음을 찾지 못했어요 — 멜로디가 들어 있는 악보인지 확인해주세요"
        }
    }

    func detachScore() {
        importedScore = nil
        importedScoreName = nil
        scoreImportMessage = nil
        reanalyzeWithCurrentScore()
    }

    /// 이미 부른 소리를 그대로 다시 분석한다 — **다시 부르게 하지 않는다.**
    ///
    /// `recentVoiceBuffer`는 분석에 넘겼던 정규화 후 샘플이라(`applyQuickRecordResult` 참고)
    /// 그대로 다시 넣으면 같은 조건에서 악보만 바뀐 결과가 나온다.
    func reanalyzeWithCurrentScore() {
        guard !recentVoiceBuffer.isEmpty else { return }

        let samples = recentVoiceBuffer
        let rate = recentVoiceSampleRate
        let score = importedScore

        // 빠른 녹음과 같은 세대 토큰 — 재분석 중에 새로 녹음하면 늦게 끝난 이쪽 결과가
        // 새 시도를 덮어쓰지 않게 한다.
        let token = UUID()
        activeAnalysisToken = token
        quickRecordPhase = .analyzing(.voiceAnalysis)

        Task {
            let analyzed = await Task.detached(priority: .userInitiated) {
                RecordingAnalyzer.analyze(recordingSamples: samples, sampleRate: rate, reference: score)
            }.value
            guard activeAnalysisToken == token else { return }
            applyQuickRecordResult(analyzed)
        }
    }
}
