import SwiftUI
import WebKit

/// [VexFlow](https://www.vexflow.com)(오선보 렌더링 오픈소스 JS 라이브러리, MIT 라이선스,
/// `HarmonyUp/Sources/Resources/VexFlowScore/`에 벤더링)로 그린 정통 오선보. 직접 구현한
/// `StaffGeometry`/`SheetMusicView`(56절)가 "보기 힘들다"는 반려를 받아, 사용자가 직접
/// 제안한 VexFlow로 전면 교체했다(docs/CONCEPTS.md 57절).
///
/// **아키텍처**: `WKWebView`가 로컬 HTML(`score.html`, CDN 없이 완전 오프라인)을 로드하고,
/// Swift가 `melodySteps`+`mutedVoices`를 JSON으로 만들어 `window.renderScore(data)`를
/// 직접 호출한다(단방향 브릿지 — JS에서 Swift로 돌아올 데이터가 없어 메시지 핸들러 불필요).
///
/// **성부 배치**: 레퍼런스 악보(사용자 제공)처럼 성부마다 자기 오선을 갖는다 — 멜로디(위)부터
/// 5도·3도(둘 다 높은음자리표)·베이스(낮은음자리표) 순으로 쌓는다(실제 피치 순서와 일치).
/// `mutedVoices`(Phase 4/6에서 "내 목소리로 화음" 재생과 공유하는 그 상태)로 꺼진 성부는
/// 아예 그 줄을 안 그린다.
struct VexFlowScoreView: UIViewRepresentable {
    let steps: [MelodyStep]
    @Binding var mutedVoices: Set<PlaybackVoice>

    /// 카드에 줄 고정 높이 — 4성부(멜로디+3도+5도+베이스)가 전부 나와도 넉넉하게.
    static let preferredHeight: CGFloat = 400

    // 이 앱 전체가 다크모드를 지원하지만, 악보는 항상 흰 종이 위에 그린다(실제 악보/독서
    // 앱들의 관례) — 그래서 여기 색상은 Theme의 다이나믹 컬러가 아니라 라이트 모드 값에
    // 대응하는 고정 hex를 쓴다.
    private static let melodyColorHex = "#5959D6"
    private static let bassColorHex = "#8E8E93"
    private static let thirdColorHex = "#2CA8B5"
    private static let fifthColorHex = "#F06B5C"

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.scrollView.bounces = false
        webView.navigationDelegate = context.coordinator

        if let url = Bundle.main.url(forResource: "score", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingPayload = buildPayload()
        context.coordinator.renderIfReady()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var pendingPayload: String?
        private var isPageLoaded = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isPageLoaded = true
            renderIfReady()
        }

        func renderIfReady() {
            guard isPageLoaded, let webView, let payload = pendingPayload else { return }
            webView.evaluateJavaScript("renderScore(\(payload));")
        }
    }

    // MARK: - JSON 페이로드 구성

    private struct Payload: Encodable {
        struct Voice: Encodable {
            let clef: String
            let color: String
            let notes: [Note]
        }
        struct Note: Encodable {
            let key: String
            let sharp: Bool
            let label: String
        }
        let voices: [Voice]
    }

    private func buildPayload() -> String {
        var voiceRows: [Payload.Voice] = []

        if !mutedVoices.contains(.melody) {
            let notes = steps.compactMap { step -> Payload.Note? in
                guard step.onsetTime != nil else { return nil }
                let (key, sharp) = Self.vexFlowKey(forMIDINote: step.midiNote)
                return Payload.Note(key: key, sharp: sharp, label: step.noteName)
            }
            voiceRows.append(Payload.Voice(clef: "treble", color: Self.melodyColorHex, notes: notes))
        }

        // 실제 음높이 순서(멜로디 다음으로 5도가 3도보다 위)와 맞춰서 그린다 — ChordGenerator의
        // 보이싱 규칙상 5도가 항상 3도보다 베이스에서 더 멀리(더 높이) 떨어져 있다.
        for interval in [ChordGenerator.Interval.fifth, .third] {
            let voice = Self.playbackVoice(for: interval)
            guard !mutedVoices.contains(voice) else { continue }
            let notes = harmonyNotes(for: interval)
            voiceRows.append(Payload.Voice(clef: "treble", color: Self.colorHex(for: interval), notes: notes))
        }

        if !mutedVoices.contains(.bass) {
            let notes = harmonyNotes(for: .bass)
            voiceRows.append(Payload.Voice(clef: "bass", color: Self.colorHex(for: .bass), notes: notes))
        }

        let payload = Payload(voices: voiceRows)
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else {
            return "{\"voices\":[]}"
        }
        return json
    }

    private func harmonyNotes(for interval: ChordGenerator.Interval) -> [Payload.Note] {
        steps.compactMap { step -> Payload.Note? in
            guard step.onsetTime != nil, let note = step.harmony?.first(where: { $0.interval == interval }) else { return nil }
            let (key, sharp) = Self.vexFlowKey(forMIDINote: note.midiNote)
            let label = NoteNameConverter.convert(frequency: note.frequency)?.noteName ?? "?"
            return Payload.Note(key: key, sharp: sharp, label: label)
        }
    }

    private static func colorHex(for interval: ChordGenerator.Interval) -> String {
        switch interval {
        case .bass: return bassColorHex
        case .third: return thirdColorHex
        case .fifth: return fifthColorHex
        }
    }

    private static func playbackVoice(for interval: ChordGenerator.Interval) -> PlaybackVoice {
        switch interval {
        case .bass: return .bass
        case .third: return .third
        case .fifth: return .fifth
        }
    }

    // MIDI 노트 -> VexFlow 키 문자열("c#/4" 형식) + 샵 필요 여부. 반음(피치클래스)이 아니라
    // 다이어토닉 레터(흰건반, 옥타브당 7개) 단위로 표기하는 오선보 규칙을 그대로 따른다 —
    // 흰건반 사이 음은 바로 아래 자연음과 같은 레터를 쓰고 샵만 붙인다. 이 v1은 플랫 없이
    // 항상 샵으로만 표기한다(56절에서 이미 채택한 것과 같은 단순화).
    private static let naturalLetters: [(pitchClass: Int, letter: String)] = [
        (0, "c"), (2, "d"), (4, "e"), (5, "f"), (7, "g"), (9, "a"), (11, "b")
    ]

    private static func vexFlowKey(forMIDINote midiNote: Int) -> (key: String, sharp: Bool) {
        let octave = midiNote / 12 - 1 // MIDI 60 = C4 관례(이 프로젝트 전반과 동일)
        let pitchClass = midiNote.mod(12)
        if let match = naturalLetters.first(where: { $0.pitchClass == pitchClass }) {
            return ("\(match.letter)/\(octave)", false)
        }
        let below = naturalLetters.last(where: { $0.pitchClass < pitchClass })!
        return ("\(below.letter)/\(octave)", true)
    }
}
