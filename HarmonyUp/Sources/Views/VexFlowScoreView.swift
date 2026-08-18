import SwiftUI
import WebKit

/// [VexFlow](https://www.vexflow.com)(오선보 렌더링 오픈소스 JS 라이브러리, MIT 라이선스,
/// `HarmonyUp/Sources/Resources/VexFlowScore/`에 벤더링)로 그린 정통 오선보. 직접 구현한
/// `StaffGeometry`/`SheetMusicView`(56절)가 "보기 힘들다"는 반려를 받아, 사용자가 직접
/// 제안한 VexFlow로 전면 교체했다(docs/CONCEPTS.md 57절).
///
/// **아키텍처**: `WKWebView`가 로컬 HTML(`score.html`, CDN 없이 완전 오프라인)을 로드하고,
/// Swift가 `melodySteps`+`mutedVoices`를 JSON으로 만들어 `window.renderScore(data)`를
/// 직접 호출한다(Swift→JS). 음표를 탭하면 그 지점부터 재생하는 기능(74절)을 위해 반대 방향
/// 브릿지도 있다 — JS가 `WKScriptMessageHandler`("harmonyUpNoteTap")로 탭한 스텝 인덱스를
/// Swift에 돌려준다.
///
/// **성부 배치**: 레퍼런스 악보(사용자 제공)처럼 성부마다 자기 오선을 갖는다 — 멜로디(위)부터
/// 5도·3도(둘 다 높은음자리표)·베이스(낮은음자리표) 순으로 쌓는다(실제 피치 순서와 일치).
/// `mutedVoices`(Phase 4/6에서 "내 목소리로 화음" 재생과 공유하는 그 상태)로 꺼진 성부는
/// 아예 그 줄을 안 그린다.
struct VexFlowScoreView: UIViewRepresentable {
    let steps: [MelodyStep]
    @Binding var mutedVoices: Set<PlaybackVoice>
    /// 지금 소리 나는 스텝(`steps`의 인덱스, `nil`이면 표시 안 함) — 애플 뮤직 가사 하이라이트
    /// 방식으로 이 스텝의 음표만 검정에서 오렌지로 바뀐다(74절). 재생 중 50ms마다 바뀌는
    /// 값이라, `updateUIView`가 이 값 하나 바뀔 때마다 악보 전체를 다시 그리면 낭비고 스크롤
    /// 위치도 리셋된다(render.js 상단 주석과 같은 이유) — 그래서 `Coordinator`가 페이로드
    /// (악보 내용) 변경과 이 값 변경을 구분해서 다르게 처리한다.
    let activeStepIndex: Int?
    /// 악보의 음표를 탭했을 때(애플 뮤직 가사 탭과 동일한 상호작용) 호출된다 — 인자는 탭한
    /// 스텝 인덱스(`steps`의 인덱스, `activeStepIndex`와 같은 좌표계).
    let onSeekToStep: (Int) -> Void
    /// 지금 웹뷰가 로드 중이거나 `renderScore` 자바스크립트 호출이 아직 안 끝났으면 true —
    /// 실기기에서 웹뷰 프로세스 자체가 늦게 뜨는 경우(76절)가 있어서, 이 시간 동안 화면이 그냥
    /// 비어 보이면 "먹통인가?" 싶을 수 있다. 호출부가 이 값으로 로딩 표시를 겹쳐 보여준다.
    @Binding var isRendering: Bool

    /// 카드에 줄 고정 높이 — "너무 작다"는 실기기 피드백으로 키웠다(docs/CONCEPTS.md 58절).
    /// 4성부가 전부 나올 때 필요한 높이보다는 작을 수 있는데, `score.html`이 세로 스크롤도
    /// 지원해서(58절) 잘리지 않고 스크롤로 볼 수 있다.
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
        webView.navigationDelegate = context.coordinator

        if let url = Bundle.main.url(forResource: "score", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.pendingPayload = buildPayload()
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
        var pendingStepIndex: Int?
        var onNoteTapped: ((Int) -> Void)?
        var isRenderingBinding: Binding<Bool>?
        private var isPageLoaded = false
        // 마지막으로 실제 renderScore를 호출한 페이로드 — 이 값이 그대로면(하이라이트만 움직인
        // 경우) 악보를 다시 그리지 않고 setActiveStep만 부른다.
        private var lastRenderedPayload: String?
        // 마지막으로 실제 setActiveStep(...)을 보낸 스텝 인덱스 — 재생 중엔 SwiftUI가
        // activePlaybackStepIndex 말고 다른 상태(예: statusText) 변화로도 body를 재평가해서
        // updateUIView가 초당 최대 20번(재생헤드 타이머 주기)까지 불릴 수 있는데, 같은 인덱스를
        // 매번 무조건 웹뷰에 다시 보내면(evaluateJavaScript IPC 왕복) 재생 중 CPU를 불필요하게
        // 더 갉아먹는다 — 값이 실제로 바뀔 때만 보낸다. hasSentStepIndex가 false면 "아직 한 번도
        // 안 보냄"이라 값이 nil이라도 최초 1회는 보내야 한다(Optional을 이중으로 감싸는 대신
        // 별도 Bool로 구분).
        private var lastSentStepIndex: Int?
        private var hasSentStepIndex = false
        // 렌더링을 새로 시작할 때마다 늘어나는 세대 토큰 — evaluateJavaScript 완료 콜백과
        // 아래 타임아웃 안전망이 서로 다른 렌더링 요청을 잘못 끄지 않도록 구분한다.
        private var renderGeneration = 0

        deinit {
            contentController?.removeScriptMessageHandler(forName: VexFlowScoreView.noteTapMessageName)
        }

        // Binding 대입은 SwiftUI 뷰 업데이트 도중(updateUIView가 부른 renderIfReady 안)이나
        // 비동기 콜백(evaluateJavaScript 완료 핸들러, WKNavigationDelegate) 어느 쪽에서
        // 불릴지 몰라서, 항상 다음 런루프로 미룬다 — 뷰 업데이트 도중 같은 뷰의 상태를 동기로
        // 바꾸면 SwiftUI가 "Modifying state during view update" 경고를 낸다.
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

        // 기존엔 로드 성공(didFinish)만 처리하고 실패는 그냥 무시했다 — 실패하면 isPageLoaded가
        // 영원히 false로 남아서 renderIfReady()의 guard에 막혀 아무 자바스크립트도 안 불리고,
        // 화면엔 그냥 빈 웹뷰만 남는데 왜 그런지 알 방법이 없었다(실기기에서 "악보가 안 보인다"는
        // 제보를 받고서야 이 공백을 발견 — 75절 이후). 최소한 원인이 로드 실패인지는 로그로
        // 구분할 수 있게 남긴다. 로딩 표시도 여기서 꺼야 한다 — 안 그러면 실패했는데도 "만드는
        // 중"이라고 영원히 거짓말하게 된다.
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
            guard isPageLoaded, let webView, let payload = pendingPayload else { return }
            if payload != lastRenderedPayload {
                renderGeneration += 1
                let generation = renderGeneration
                setRendering(true)
                webView.evaluateJavaScript("renderScore(\(payload));") { [weak self] _, error in
                    #if DEBUG
                    if let error { print("[VexFlowScoreView] renderScore 호출 실패: \(error.localizedDescription)") }
                    #endif
                    self?.finishRendering(generation: generation)
                }
                lastRenderedPayload = payload
                // 방금 새로 그린 악보는 JS 쪽 noteState.activeIndex가 nil로 초기화돼 있다
                // (render.js의 renderScore) — Swift 쪽 dedup 기록도 같이 리셋해서, 아래
                // setActiveStep이 "값은 그대로니까 생략"하지 않고 반드시 한 번은 다시 보내게 한다.
                hasSentStepIndex = false

                // evaluateJavaScript의 완료 콜백이 실제로 항상 불린다는 보장이 없다 —
                // WKWebView의 WebContent 프로세스가 응답 없어지는 경우(76절에서 실기기 로그로
                // 이미 확인됨)엔 콜백 자체가 영영 안 올 수 있다. 콜백만 믿으면 "악보를 만드는
                // 중이에요"가 실제로는 다 만들어졌거나 영영 실패했는데도 화면에 계속 남아
                // 레이아웃을 가리는 문제가 생긴다 — 일정 시간 안에 콜백이 안 오면 강제로
                // 로딩 표시를 꺼서 최소한 화면이 영구히 막히지는 않게 한다. renderGeneration으로
                // 그 사이 새 렌더링이 시작됐으면(더 최신 콜백이 처리할 일이므로) 이 타이머는
                // 아무 것도 안 하게 막는다.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    #if DEBUG
                    if self?.renderGeneration == generation {
                        print("[VexFlowScoreView] renderScore 완료 콜백이 8초 안에 안 와서 타임아웃으로 로딩 표시를 끔")
                    }
                    #endif
                    self?.finishRendering(generation: generation)
                }
            }

            // 재생 중엔 재생헤드 타이머(50ms)가 activeStepIndex 말고 다른 상태 변화로도
            // updateUIView를 초당 최대 20번까지 다시 부를 수 있는데, 같은 인덱스를 매번
            // 무조건 웹뷰에 다시 보내면 그만큼 evaluateJavaScript IPC 왕복이 늘어나 재생
            // 중 CPU를 다툰다("녹음 듣는데 음이 끊긴다" 재생 끊김 제보와 같은 계열) — 값이
            // 실제로 바뀌었을 때만 보낸다.
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

        /// `generation`이 지금 진행 중인 렌더링과 같을 때만 로딩 표시를 끈다 — 완료 콜백과
        /// 타임아웃 안전망 둘 다 이 함수를 거치므로, 둘 중 뭐가 먼저 오든 안전하고, 그 사이
        /// 새 렌더링이 시작된 뒤라면(세대가 달라짐) 무시된다.
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
        // key가 nil이면 쉼표(그 성부가 이 스텝엔 음이 없다는 뜻 — 온음계 밖 멜로디 음이라
        // 화음을 못 정의한 경우 등). duration은 RhythmQuantizer가 실제 길이(초)로 정한
        // VexFlow 음표 코드("8"/"q"/"qd"/"h") — 모든 성부가 항상 4분음표로만 그려져서
        // "인위적으로 보인다"는 피드백을 받아 추가했다(docs/CONCEPTS.md 59절).
        struct Note: Encodable {
            let key: String?
            let sharp: Bool
            let duration: String
        }
        let voices: [Voice]
        // 전 성부가 공유하는 마디 구성("이 마디엔 음 몇 개") — 모든 성부가 같은 `MelodyStep`
        // 타이밍을 공유하므로, 이 하나의 구성을 그대로 써야 성부끼리 같은 순간의 음이 화면에서
        // 세로로 정확히 맞는다(쉼표로 빈 자리를 채우는 것과 짝을 이루는 정렬 보장).
        let measureBreaks: [Int]
    }

    private func buildPayload() -> String {
        let validSteps = steps.filter { $0.onsetTime != nil }
        guard !validSteps.isEmpty else {
            return "{\"voices\":[],\"measureBreaks\":[]}"
        }

        let quantized = RhythmQuantizer.quantize(durations: validSteps.map { $0.duration ?? 0.3 })
        let measureBreaks = RhythmQuantizer.measureBreaks(notes: quantized)

        var voiceRows: [Payload.Voice] = []

        if !mutedVoices.contains(.melody) {
            let notes = zip(validSteps, quantized).map { step, quantizedNote -> Payload.Note in
                let (key, sharp) = Self.vexFlowKey(forMIDINote: step.midiNote)
                return Payload.Note(key: key, sharp: sharp, duration: quantizedNote.vexFlowDuration)
            }
            // 예전엔 멜로디를 항상 높은음자리표로 고정했었다 — 낮은 음역(예: C3 근처)을 부르면
            // 높은음자리표 기준으론 덧줄이 여러 개 필요해서 오선 한참 아래로 내려가 보였다
            // ("c3인데 완전 아래에 내려가 있다" 피드백). 실제 악보처럼 그 성부가 실제로 부른
            // 음역에 맞는 음자리표를 골라야 한다.
            let clef = Self.clef(forMIDINotes: validSteps.map(\.midiNote))
            voiceRows.append(Payload.Voice(clef: clef, notes: notes))
        }

        // 실제 음높이 순서(멜로디 다음으로 5도가 3도보다 위)와 맞춰서 그린다 — ChordGenerator의
        // 보이싱 규칙상 5도가 항상 3도보다 베이스에서 더 멀리(더 높이) 떨어져 있다. 다만 이
        // 순서는 "위에서 아래로 쌓는 순서"일 뿐, 각 성부 자기 오선의 음자리표는 멜로디와 같은
        // 이유로 그 성부가 실제로 부르는(생성된) 음역에 맞춰 따로 고른다 — 멜로디가 낮으면
        // 3도/5도도 덩달아 낮아지므로(베이스 기준으로 보이싱되니까) 무조건 높은음자리표로
        // 고정하면 똑같이 덧줄 문제가 생긴다.
        for interval in [ChordGenerator.Interval.fifth, .third] {
            let voice = Self.playbackVoice(for: interval)
            guard !mutedVoices.contains(voice) else { continue }
            let notes = harmonyNotes(for: interval, steps: validSteps, quantized: quantized)
            let midiNotes = validSteps.compactMap { $0.harmony?.first(where: { $0.interval == interval })?.midiNote }
            voiceRows.append(Payload.Voice(clef: Self.clef(forMIDINotes: midiNotes), notes: notes))
        }

        if !mutedVoices.contains(.bass) {
            let notes = harmonyNotes(for: .bass, steps: validSteps, quantized: quantized)
            voiceRows.append(Payload.Voice(clef: "bass", notes: notes))
        }

        let payload = Payload(voices: voiceRows, measureBreaks: measureBreaks)
        guard let data = try? JSONEncoder().encode(payload), let json = String(data: data, encoding: .utf8) else {
            return "{\"voices\":[],\"measureBreaks\":[]}"
        }
        return json
    }

    /// steps/quantized는 항상 같은 길이(둘 다 validSteps 기준)라, 화음이 없는 스텝은 건너뛰지
    /// 않고 쉼표(key: nil)로 채운다 — 그래야 모든 성부의 음 배열 길이가 똑같이 유지돼서
    /// `measureBreaks`를 그대로 공유해도 어긋나지 않는다.
    private func harmonyNotes(for interval: ChordGenerator.Interval, steps: [MelodyStep], quantized: [RhythmQuantizer.QuantizedNote]) -> [Payload.Note] {
        zip(steps, quantized).map { step, quantizedNote -> Payload.Note in
            guard let note = step.harmony?.first(where: { $0.interval == interval }) else {
                return Payload.Note(key: nil, sharp: false, duration: quantizedNote.vexFlowDuration)
            }
            let (key, sharp) = Self.vexFlowKey(forMIDINote: note.midiNote)
            return Payload.Note(key: key, sharp: sharp, duration: quantizedNote.vexFlowDuration)
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

    /// 한 성부의 실제 음역(그 성부가 이번 녹음에서 부른/생성된 MIDI 노트들)을 보고 어느
    /// 음자리표가 자연스러운지 고른다. MIDI 60(미들 C)을 그대로 기준 삼지 않고 조금 낮춘
    /// 이유: 높은음자리표는 미들 C보다 아래에서도 어느 정도(첫째 줄=E4=MIDI64까지) 덧줄 없이
    /// 표현되니, 평균이 그보다 살짝만 낮아도 굳이 낮은음자리표로 넘길 필요는 없다 — 대신
    /// 낮은음자리표 가운데줄(D3=MIDI50)에 걸치는 지점을 기준으로 삼는다.
    private static func clef(forMIDINotes midiNotes: [Int]) -> String {
        guard !midiNotes.isEmpty else { return "treble" }
        let average = midiNotes.reduce(0, +) / midiNotes.count
        return average < 57 ? "bass" : "treble" // 57 = A3, 낮은음자리표 셋째줄 바로 위
    }
}
