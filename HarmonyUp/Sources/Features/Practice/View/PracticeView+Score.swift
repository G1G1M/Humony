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

    /// 파일 고르기에서 열어줄 형식.
    ///
    /// **`.data`를 넣어 사실상 모든 파일을 고를 수 있게 한다.** 형식 목록으로 조이면 정작
    /// 넣어야 할 파일이 회색으로 비활성화되는 일이 생긴다 — `.musicxml`처럼 시스템에 등록된
    /// 타입이 없는 확장자는 파일마다 임시 타입(dynamic UTI)이 붙어 목록과 안 맞을 수 있고,
    /// 같은 MusicXML이어도 어디서 받았느냐에 따라 `public.xml`이 아니라 그냥 데이터로 잡히기도
    /// 한다. 무엇을 받아들이는지는 고른 **뒤에** 확장자로 판단하고, 아니면 무엇을 넣어야
    /// 하는지 알려주는 편이 사용자에게 훨씬 낫다(`ScoreImporter.load` + `importErrorMessage`).
    static var scoreContentTypes: [UTType] {
        [UTType(filenameExtension: "musicxml"), UTType(filenameExtension: "mxl"), UTType.xml, UTType.midi, UTType.image, UTType.data]
            .compactMap { $0 }
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
                scoreImportMessage = Self.importErrorMessage(error, fileName: url.lastPathComponent)
                #if DEBUG
                print("[PracticeView] 악보 파일 읽기 실패 — \(url.lastPathComponent) (\(url.pathExtension)): \(error)")
                #endif
            }

        case let .failure(error):
            // 시트를 그냥 닫은 것은 실패가 아니다 — 에러 문구를 띄우면 뭘 잘못한 것처럼 보인다.
            guard (error as NSError).code != NSUserCancelledError else { return }
            scoreImportMessage = "악보를 열지 못했어요 — \(error.localizedDescription)"
        }
    }

    static func importErrorMessage(_ error: Error, fileName: String? = nil) -> String {
        guard let importError = error as? ScoreImporter.ImportError else {
            return "악보를 읽지 못했어요 — 다른 파일로 시도해주세요"
        }
        // 무엇을 골랐는지 되짚어주면 "왜 안 되지"를 훨씬 빨리 안다(특히 .mxl 같은 사촌 형식).
        let picked = fileName.map { "\u{2018}\($0)\u{2019}은 " } ?? ""
        switch importError {
        case .unsupportedFileType:
            return picked + "지원하지 않는 형식이에요 — 악보 사진이나 MusicXML(.musicxml/.xml/.mxl)·MIDI(.mid)가 필요해요. PDF는 캡처해서 사진으로 넣어주세요"
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

    // MARK: - ② 악보 비교 관문 (158절)

    /// 부른 뒤 처음 보게 되는 화면 — 악보를 붙여 대조하고, 확인한 뒤에 화음으로 넘어간다.
    ///
    /// 악보를 안 붙인 사람도 여기를 지난다. 그때는 "붙이기"와 "그대로 진행"만 있는 가벼운
    /// 화면이다 — **악보 없는 흐름이 막히면 안 된다.**
    @ViewBuilder
    var scoreReviewSection: some View {
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
                } else {
                    Text("악보를 붙이면 부른 음을 악보에 맞춰 다듬어요. 그냥 넘어가도 괜찮아요")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

                HStack(spacing: Theme.Spacing.sm) {
                    attachScoreMenu(label: importedScoreName == nil ? "악보 붙이기" : "다른 악보")
                    if importedScoreName != nil {
                        Button("떼기") { detachScore() }
                            .harmonyButtonStyle(prominent: false)
                            .disabled(quickRecordPhase.isRecordingOrAnalyzing || isReadingScoreImage)
                    }
                }

                Button {
                    withAnimation { resultStage = .harmony }
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(importedScoreName == nil ? "그대로 화음 만들기" : "이대로 화음 만들기")
                        Image(systemName: "arrow.right")
                    }
                    .frame(maxWidth: .infinity)
                }
                .harmonyButtonStyle(prominent: true)
                .disabled(quickRecordPhase.isRecordingOrAnalyzing || isReadingScoreImage)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("악보와 대조")
    }

    /// ③ 화음 결과에서 ②로 되돌아가는 줄 — 악보를 바꿔 다시 보고 싶을 때.
    var backToScoreReviewRow: some View {
        Button {
            withAnimation { resultStage = .reviewingScore }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "chevron.left")
                Text(importedScoreName == nil ? "악보 붙이기" : "악보 다시 보기")
            }
            .font(Theme.Typography.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityHint("악보와 대조하는 화면으로 돌아가요")
    }

    /// 비교 단계에서 악보 자리에 그릴 "부른 대로 / 교정 후" 두 줄.
    ///
    /// 교정이 적용되지 않았으면(악보가 없거나 잘 안 맞아 포기했으면) 비교할 게 없으므로 nil —
    /// 그때는 평소의 4성부 악보를 그대로 보여준다.
    var scoreComparisonPayloadJSON: String? {
        guard let comparison = scoreComparison, comparison.isApplied else { return nil }
        let before = comparison.notesBeforeCorrection.map(\.midiNote)
        let after = melodySteps.map(\.midiNote)
        guard before != after else { return nil }   // 하나도 안 바뀌었으면 두 줄이 똑같다
        return ScoreComparisonPayload.json(beforeMIDINotes: before, afterMIDINotes: after)
    }
}
