import CoreGraphics
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 부른 뒤 악보를 붙여 채보를 대조·교정하는 흐름 (155절).
///
/// **왜 녹음 전이 아니라 녹음 뒤에 붙이는가**(사용자 결정): 녹음 화면에서 준비할 게 늘어나지
/// 않고, 이미 부른 소리를 그대로 둔 채 악보를 바꿔가며 비교해볼 수 있다. 원본 목소리
/// (`recentVoiceBuffer`)를 계속 들고 있기 때문에 악보를 붙이면 **다시 부르지 않고 재분석**만
/// 하면 된다.
extension PracticeView {

    /// 파일에서 받아들이는 악보 형식. 사진은 파일 앱에서 골라도 되고(여기 `.image`),
    /// 앨범이나 카메라에서 바로 가져와도 된다(156절).
    static var scoreContentTypes: [UTType] {
        [UTType(filenameExtension: "musicxml"), UTType.xml, UTType.midi, UTType.image]
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
                        attachScoreMenu(label: "다른 악보")
                        Button("떼기") { detachScore() }
                            .harmonyButtonStyle(prominent: false)
                    }
                    .disabled(quickRecordPhase.isRecordingOrAnalyzing)
                } else {
                    Text("악보 사진을 찍어 붙이면 부른 음을 악보에 맞춰 다듬어요")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    attachScoreMenu
                }

                if isReadingScoreImage {
                    HStack(spacing: Theme.Spacing.xs) {
                        ProgressView().controlSize(.small)
                        Text("악보를 읽는 중이에요")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.secondary)
                    }
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
            return "악보 사진이나 MusicXML(.musicxml/.xml)·MIDI(.mid) 파일이 필요해요 — PDF는 캡처해서 사진으로 넣어주세요"
        case .malformed:
            return "악보를 읽지 못했어요 — 다른 파일이나 사진으로 시도해주세요"
        case .noNotesFound:
            return "악보에서 음표를 찾지 못했어요 — 오선과 음표가 또렷하게 나오도록 다시 찍어주세요"
        case .noStaffFound:
            return "사진에서 오선을 찾지 못했어요 — 악보가 화면을 가득 채우게, 너무 기울지 않게 찍어주세요"
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

    /// 악보를 가져오는 세 갈래 — 찍기 / 앨범 / 파일.
    ///
    /// **찍기를 맨 위에 둔다.** 사람들이 실제로 손에 쥐고 있는 건 종이 악보지 MusicXML
    /// 파일이 아니다(그게 이 기능을 만든 이유다).
    func attachScoreMenu(label: String = "악보 붙이기") -> some View {
        Menu {
            if CameraPicker.isAvailable {
                Button {
                    isCapturingScorePhoto = true
                } label: {
                    Label("사진 찍기", systemImage: "camera")
                }
            }
            Button {
                isPickingScorePhoto = true
            } label: {
                Label("앨범에서 고르기", systemImage: "photo.on.rectangle")
            }
            Button {
                isImportingScore = true
            } label: {
                Label("파일에서 (MusicXML·MIDI)", systemImage: "folder")
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "paperclip")
                Text(label)
            }
            .frame(maxWidth: .infinity)
        }
        .harmonyButtonStyle(prominent: false)
        .disabled(quickRecordPhase.isRecordingOrAnalyzing || isReadingScoreImage)
    }

    /// 메뉴 없이 버튼 하나로 쓰는 자리(첫 첨부).
    var attachScoreMenu: some View {
        attachScoreMenu(label: "악보 붙이기")
    }

    // MARK: - 사진에서 읽기 (156절)

    func handlePickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                scoreImportMessage = "사진을 불러오지 못했어요 — 다시 골라주세요"
                return
            }
            readScoreImage(data: data, name: "앨범 사진")
        }
    }

    /// 사진 해독은 메인 스레드에서 하면 안 된다 — 1600픽셀 사진 한 장에 오선 검출·구멍
    /// 메우기·창 훑기가 모두 돌아서 화면이 눈에 띄게 멈춘다(녹음 분석을 `Task.detached`로
    /// 옮긴 것과 같은 이유다).
    func readScoreImage(data: Data, name: String) {
        isReadingScoreImage = true
        scoreImportMessage = nil

        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ScoreImporter.ImportedScore, Error> in
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    return .failure(ScoreImporter.ImportError.malformed)
                }
                do {
                    return .success(try SheetMusicImageReader.read(cgImage))
                } catch {
                    return .failure(error)
                }
            }.value

            isReadingScoreImage = false
            switch outcome {
            case let .success(score):
                importedScore = score
                importedScoreName = name
                reanalyzeWithCurrentScore()
            case let .failure(error):
                importedScore = nil
                importedScoreName = nil
                scoreImportMessage = Self.importErrorMessage(error)
            }
        }
    }
}
