import SwiftUI
import WebKit

/// [VexFlow](https://www.vexflow.com)(오선보 렌더링 오픈소스 JS 라이브러리, MIT 라이선스,
/// `HarmonyUp/Sources/Resources/VexFlowScore/`에 벤더링)로 그린 정통 오선보. 직접 구현한
/// `StaffGeometry`/`SheetMusicView`(56절)가 "보기 힘들다"는 반려를 받아, 사용자가 직접
/// 제안한 VexFlow로 전면 교체했다(docs/CONCEPTS.md 57절).
///
/// **아키텍처**: `WKWebView`가 로컬 HTML(`score.html`, CDN 없이 완전 오프라인)을 로드하고,
/// Swift가 `melodySteps`를 JSON으로 만들어 `window.renderScore(data)`를 직접 호출한다
/// (Swift→JS). 탭하면 그 지점부터 재생하는 기능(74절)을 위해 반대 방향 브릿지도 있다 — JS가
/// `WKScriptMessageHandler`("harmonyUpNoteTap")로 탭한 스텝 인덱스를 Swift에 돌려준다.
///
/// **2026-08-20, 멜로디 전용으로 축소**: 화음 API(피치시프트/합성/베이스·3도·5도 재생) 전체를
/// 걷어내면서, 이 뷰도 성부별 오선(멜로디/5도/3도/베이스)+뮤트 토글 구조에서 **멜로디 단일
/// 오선**으로 줄였다. `onSeekToStep`은 예전엔 화음 재생 탐색용이었는데 지금은 재생 자체가
/// 없어 호출부가 항상 무시하는(no-op) 콜백을 넘긴다 — 탭하면 JS 쪽 시각 피드백(살짝
/// 눌렸다 돌아오는)만 남고 기능은 없다.
struct VexFlowScoreView: UIViewRepresentable {
    let steps: [MelodyStep]
    /// 지금 소리 나는 스텝(`steps`의 인덱스, `nil`이면 표시 안 함) — 재생 기능이 없는
    /// 지금은 호출부가 항상 `nil`을 넘긴다(재도입 시를 대비해 파라미터 자체는 남겨둠).
    let activeStepIndex: Int?
    /// 악보의 음표를 탭했을 때 호출된다 — 지금은 재생이 없어 호출부가 no-op을 넘긴다.
    let onSeekToStep: (Int) -> Void
    /// 지금 웹뷰가 로드 중이거나 `renderScore` 자바스크립트 호출이 아직 안 끝났으면 true —
    /// 실기기에서 웹뷰 프로세스 자체가 늦게 뜨는 경우(76절)가 있어서, 이 시간 동안 화면이 그냥
    /// 비어 보이면 "먹통인가?" 싶을 수 있다. 호출부가 이 값으로 로딩 표시를 겹쳐 보여준다.
    @Binding var isRendering: Bool
    /// 악보 "내용"이 실제로 바뀔 때만 올라가는 세대 번호 — 호출부가 `melodySteps`를 새로
    /// 채울 때만 증가시킨다. 정수 하나만 비교하는 이 방식이면 "다시 그려야 하는지" 판단이
    /// 명시적으로 버전을 올린 시점에만 참이 되므로, 재생 중(예전엔 재생헤드 타이머) 불필요한
    /// 재렌더를 구조적으로 막는다.
    let contentVersion: Int

    /// 카드에 줄 고정 높이 — "너무 작다"는 실기기 피드백으로 키웠다(docs/CONCEPTS.md 58절).
    static let preferredHeight: CGFloat = 460

    /// JS가 탭 이벤트를 돌려보내는 메시지 핸들러 이름 — `render.js`의 `addTapRegions()`가
    /// 같은 이름으로 `postMessage`를 호출한다.
    private static let noteTapMessageName = "harmonyUpNoteTap"

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: Self.noteTapMessageName)
        context.coordinator.contentController = configuration.userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .white
        webView.scrollView.backgroundColor = .white
        webView.scrollView.bounces = false
        // 악보는 가로(음표 흐름)/세로(카드 높이를 넘칠 때) 둘 다 스크롤 가능한데(score.html
        // #scoreWrapper), 컴팩트 레이아웃에서는 이 웹뷰가 SwiftUI의 세로 ScrollView 안에
        // 얹혀 있다. 방향 잠금을 켜서 손가락이 처음 움직인 방향으로만 이 안쪽 스크롤이
        // 반응하게 하면, 대각선 드래그 때 안쪽·바깥쪽 스크롤이 동시에 애매하게 반응하는 걸 줄인다.
        webView.scrollView.isDirectionalLockEnabled = true
        // 기본값(true)은 터치 시작 후 일정 시간 지나야 콘텐츠가 반응한다 — 음표 탭
        // 히트 영역(addTapRegions)이 "딜레이 없이 즉시" 반응해야 하는 요구사항과 맞지 않아 끈다.
        webView.scrollView.delaysContentTouches = false
        webView.navigationDelegate = context.coordinator

        if let url = Bundle.main.url(forResource: "score", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 버전이 실제로 안 바뀌었으면 굳이 buildPayload()를 다시 돌리지 않는다.
        if context.coordinator.lastRenderedVersion != contentVersion {
            context.coordinator.pendingPayload = buildPayload()
        }
        context.coordinator.pendingVersion = contentVersion
        context.coordinator.pendingStepIndex = activeStepIndex
        context.coordinator.onNoteTapped = onSeekToStep
        context.coordinator.isRenderingBinding = $isRendering
        context.coordinator.renderIfReady()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        // userContentController가 코디네이터를 강하게 붙잡고 있어서(add(_:name:)), 반대로
        // 여기서 강하게 잡으면 서로 놓아주지 못하는 순환 참조가 된다 — weak로만 들고, deinit에서
        // 핸들러를 명시적으로 떼어낸다.
        weak var contentController: WKUserContentController?
        var pendingPayload: String?
        var pendingVersion: Int?
        var pendingStepIndex: Int?
        var onNoteTapped: ((Int) -> Void)?
        var isRenderingBinding: Binding<Bool>?
        private var isPageLoaded = false
        // 마지막으로 실제 renderScore를 호출한 버전 — 이 값이 그대로면(하이라이트만 움직인
        // 경우) 악보를 다시 그리지 않고 setActiveStep만 부른다.
        var lastRenderedVersion: Int?
        // 값이 실제로 바뀌었을 때만 웹뷰에 다시 보낸다(evaluateJavaScript IPC 왕복 절약).
        private var lastSentStepIndex: Int?
        private var hasSentStepIndex = false
        // 렌더링을 새로 시작할 때마다 늘어나는 세대 토큰 — evaluateJavaScript 완료 콜백과
        // 아래 타임아웃 안전망이 서로 다른 렌더링 요청을 잘못 끄지 않도록 구분한다.
        private var renderGeneration = 0

        deinit {
            contentController?.removeScriptMessageHandler(forName: VexFlowScoreView.noteTapMessageName)
        }

        // Binding 대입은 SwiftUI 뷰 업데이트 도중이나 비동기 콜백 어느 쪽에서 불릴지 몰라서,
        // 항상 다음 런루프로 미룬다 — 뷰 업데이트 도중 같은 뷰의 상태를 동기로 바꾸면
        // SwiftUI가 "Modifying state during view update" 경고를 낸다.
        private func setRendering(_ value: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.isRenderingBinding?.wrappedValue = value
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            #if DEBUG
            print("[VexFlowScoreView] score.html 로드 완료")
            #endif
            isPageLoaded = true
            renderIfReady()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            #if DEBUG
            print("[VexFlowScoreView] score.html 로드 실패(didFail): \(error.localizedDescription)")
            #endif
            setRendering(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            #if DEBUG
            print("[VexFlowScoreView] score.html 로드 실패(didFailProvisionalNavigation): \(error.localizedDescription)")
            #endif
            setRendering(false)
        }

        func renderIfReady() {
            guard isPageLoaded, let webView else { return }
            if pendingVersion != lastRenderedVersion, let payload = pendingPayload {
                #if DEBUG
                print("[VexFlowScoreView] 버전 변경 감지(\(String(describing: lastRenderedVersion)) -> \(String(describing: pendingVersion))) — 악보 다시 그림")
                #endif
                renderGeneration += 1
                let generation = renderGeneration
                setRendering(true)
                webView.evaluateJavaScript("renderScore(\(payload));") { [weak self] _, error in
                    #if DEBUG
                    if let error { print("[VexFlowScoreView] renderScore 호출 실패: \(error.localizedDescription)") }
                    #endif
                    self?.finishRendering(generation: generation)
                }
                lastRenderedVersion = pendingVersion
                pendingPayload = nil
                hasSentStepIndex = false

                // evaluateJavaScript의 완료 콜백이 실제로 항상 불린다는 보장이 없다(76절) —
                // 일정 시간 안에 콜백이 안 오면 강제로 로딩 표시를 꺼서 화면이 영구히 막히지 않게 한다.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    #if DEBUG
                    if self?.renderGeneration == generation {
                        print("[VexFlowScoreView] renderScore 완료 콜백이 8초 안에 안 와서 타임아웃으로 로딩 표시를 끔")
                    }
                    #endif
                    self?.finishRendering(generation: generation)
                }
            }

            guard !hasSentStepIndex || pendingStepIndex != lastSentStepIndex else { return }
            hasSentStepIndex = true
            lastSentStepIndex = pendingStepIndex
            let stepArgument = pendingStepIndex.map(String.init) ?? "null"
            webView.evaluateJavaScript("setActiveStep(\(stepArgument));") { _, error in
                #if DEBUG
                if let error { print("[VexFlowScoreView] setActiveStep 호출 실패: \(error.localizedDescription)") }
                #endif
            }
        }

        /// `generation`이 지금 진행 중인 렌더링과 같을 때만 로딩 표시를 끈다.
        private func finishRendering(generation: Int) {
            guard generation == renderGeneration else { return }
            setRendering(false)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let index = message.body as? Int else { return }
            onNoteTapped?(index)
        }
    }

    // MARK: - JSON 페이로드 구성

    private struct Payload: Encodable {
        struct Voice: Encodable {
            let clef: String
            let notes: [Note]
        }
        struct Note: Encodable {
            let key: String?
            let sharp: Bool
            let duration: String
        }
        let voices: [Voice]
        let measureBreaks: [Int]
    }

    private func buildPayload() -> String {
        let validSteps = steps.filter { $0.onsetTime != nil }
        guard !validSteps.isEmpty else {
            return "{\"voices\":[],\"measureBreaks\":[]}"
        }

        let quantized = RhythmQuantizer.quantize(durations: validSteps.map { $0.duration ?? 0.3 })
        let measureBreaks = RhythmQuantizer.measureBreaks(notes: quantized)

        let notes = zip(validSteps, quantized).map { step, quantizedNote -> Payload.Note in
            let (key, sharp) = Self.vexFlowKey(forMIDINote: step.midiNote)
            return Payload.Note(key: key, sharp: sharp, duration: quantizedNote.vexFlowDuration)
        }
        // 실제 부른 음역에 맞는 음자리표를 고른다 — 항상 높은음자리표로 고정하면 낮은 음역
        // (예: C3 근처)에서 덧줄이 여러 개 필요해 오선 한참 아래로 내려가 보인다.
        let clef = Self.clef(forMIDINotes: validSteps.map(\.midiNote))
        let voiceRows = [Payload.Voice(clef: clef, notes: notes)]

        let payload = Payload(voices: voiceRows, measureBreaks: measureBreaks)
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else {
            return "{\"voices\":[],\"measureBreaks\":[]}"
        }
        return json
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

    /// 멜로디의 실제 음역(이번 녹음에서 부른 MIDI 노트들)을 보고 어느 음자리표가 자연스러운지
    /// 고른다. MIDI 60(미들 C)을 그대로 기준 삼지 않고 조금 낮춘 이유: 높은음자리표는 미들
    /// C보다 아래에서도 어느 정도(첫째 줄=E4=MIDI64까지) 덧줄 없이 표현되니, 평균이 그보다
    /// 살짝만 낮아도 굳이 낮은음자리표로 넘길 필요는 없다 — 대신 낮은음자리표 가운데줄
    /// (D3=MIDI50)에 걸치는 지점을 기준으로 삼는다.
    private static func clef(forMIDINotes midiNotes: [Int]) -> String {
        guard !midiNotes.isEmpty else { return "treble" }
        let average = midiNotes.reduce(0, +) / midiNotes.count
        return average < 57 ? "bass" : "treble" // 57 = A3, 낮은음자리표 셋째줄 바로 위
    }
}
