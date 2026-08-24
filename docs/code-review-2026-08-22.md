# 코드 리뷰 — 2026-08-22

대상: 최근 3개 커밋(`e96df4e`, `fb0ea3c`, `b8ea258`)에서 변경된 Swift 파일 8개
(`PracticeView.swift`, `PracticeView+Capture.swift`, `PracticeView+Layout.swift`,
`QuickRecordView.swift`, `WaveformView.swift`, `RecordingPlayer.swift`,
`MelodyStep.swift`, `ChordGenerator.swift`)

참조 타입 선언부(`AudioCapture`, `MelodySession`, `VoiceHarmonyTrackBuilder`,
`PitchShifterWorldAnalysis`, World 브릿지)까지 함께 확인함.

미적용 상태. 아래 수정안은 모두 제안이며 코드에 반영하지 않았음.

---

## [심각] PracticeView+Capture.swift:172-188 — 12초 분석 타임아웃이 작동하지 않는다

`withTaskGroup`은 body 클로저가 값을 반환한 뒤 남은 자식 태스크를 전부 기다린 다음에야
반환한다(구조적 동시성 불변식). `group.cancelAll()`은 취소 플래그만 세우는데
`RecordingAnalyzer.analyze`는 동기 함수라 `Task.isCancelled`를 전혀 보지 않는다.
따라서 타임아웃 태스크가 12초에 먼저 끝나도 `analyzeWithTimeout`은 분석이 끝날 때까지
suspend된 채로 있다. 주석(169-171행)이 설명하는 "analyze는 백그라운드에서 계속 돌고
우린 먼저 빠져나온다"가 코드에서 성립하지 않는다.

재현: 60초 녹음처럼 `analyze()`가 20초 걸리는 입력. 기대 동작은 12초에 에러 카드 노출이지만,
실제로는 20초 내내 "음성 분석 중" 진행률 바에 갇혀 있다가 20초 시점에 "분석이 너무 오래
걸리고 있어요"가 뜬다. 그 시점엔 정상 결과가 이미 있는데도 `analyzed`가 nil이라 통째로 버려진다.

수정: 긴 작업을 그룹의 자식이 아니라 비구조적 태스크로 빼고, 타임아웃은 UI 상태만 먼저 넘긴다.

```swift
let token = UUID()
activeAnalysisToken = token
let work = Task.detached(priority: .userInitiated) {
    RecordingAnalyzer.analyze(recordingSamples: samples, sampleRate: rate)
}
let timeout = Task { @MainActor in
    try? await Task.sleep(nanoseconds: UInt64(analysisTimeout * 1_000_000_000))
    guard !Task.isCancelled, activeAnalysisToken == token else { return }
    activeAnalysisToken = nil            // 늦게 도착할 결과를 무시
    quickRecordPhase = .error("분석이 너무 오래 걸리고 있어요 — 다시 시도해주세요")
}
Task {
    let analyzed = await work.value
    timeout.cancel()
    guard activeAnalysisToken == token else { return }
    ...
}
```

근본 해결은 `RecordingAnalyzer.analyze`의 윈도우 루프 안에 `if Task.isCancelled { return nil }`를
넣어 실제로 취소되게 만드는 것.

---

## [심각] PracticeView+Capture.swift:371-374, 406 — WORLD 전체 분석을 메인 스레드에서 성부 수만큼 반복

`VoiceHarmonyTrackBuilder.build`는 호출될 때마다 내부에서
`PitchShifterWorldAnalysis(samples: sourceBuffer, ...)`를 새로 만든다
(VoiceHarmonyTrackBuilder.swift:68). `startVoiceHarmonyPlayback`은 성부별로 `build`를
3번(베이스/3도/5도) 호출하므로 동일한 인자로 녹음 전체 WORLD 분석(Dio+StoneMask+CheapTrick+D4C)이
3번 돈다. `PitchShifterWorldAnalysis` 헤더 주석이 명시한 설계("원본 전체로 한 번 init한 뒤
성부마다 synthesize만 반복 — 분석은 한 번만")가 호출부에서 무효화돼 있다.
`PracticeView`는 `View` 준수로 @MainActor라 이 전부가 버튼 액션 안에서 동기 실행된다.

재현: 60초 녹음 후 "내 목소리로 화음 듣기"를 누르면 소리가 나기 전까지 UI가 완전히 얼어붙는다
(스피너도 없음). 성부 뮤트 토글(`toggleMute` → 즉시 재시작)도 매번 같은 3회 분석을 다시 돌린다.

수정:
1. `build`에 분석 핸들을 주입받는 오버로드를 두고 호출부에서 한 번만 만들어 공유
2. 전체를 메인 스레드에서 떼어낸다

브릿지의 `HarmonyUpWorldSynthesizeWithF0`는 `analysis`를 const로만 읽고 작업버퍼가 전부
로컬이라, 공유 핸들로 성부별 `synthesize`를 병렬(TaskGroup) 실행하는 것도 안전하다.

```swift
static func build(melodySteps:..., analysis: PitchShifterWorldAnalysis, voice:, rate:) -> [Float]
```
```swift
isPreparingHarmony = true            // 버튼에 진행 표시
let steps = melodySteps, buffer = recentVoiceBuffer, rate = recentVoiceSampleRate
let mixed = await Task.detached(priority: .userInitiated) {
    guard let analysis = PitchShifterWorldAnalysis(samples: buffer, sampleRate: rate, d4cThreshold: 0.5)
    else { return [Float]() }
    return await withTaskGroup(of: (Int, [Float]).self) { ... }   // 성부별 synthesize 병렬
}.value
```

---

## [주의] PracticeView+Capture.swift:45-84 / AudioCapture.swift:72 — 캡처 콜백 클로저의 순환 참조

`audioCapture.start { ... }`에 넘긴 클로저는 구조체 `PracticeView`의 복사본을 통째로 캡처하고,
그 복사본은 `let audioCapture` 프로퍼티로 같은 AudioCapture 인스턴스를 강하게 참조한다.
`AudioCapture.stop()`은 탭 제거와 엔진 정지만 하고 `resultHandler`를 nil로 되돌리지 않으므로
AudioCapture → 클로저 → PracticeView 복사본 → AudioCapture 사이클이 끊기지 않는다(AVAudioEngine 포함).

재현: 녹음을 시작했다가 멈추고 탭을 떠나도(`onDisappear`의 `audioCapture.stop()`) 인스턴스가
해제되지 않는다. Instruments Leaks/Allocations에서 확인 가능.

수정: `AudioCapture.stop()` 마지막에 `resultHandler = nil` 추가(탭 콜백은 이미 `[weak self]`라 안전).
클로저 안에서 필요한 상태만 명시적으로 캡처하도록 좁히면 더 좋다.

---

## [주의] PracticeView+Layout.swift:258·260 + WaveformView.swift:36-54 — 녹음 버퍼 전체를 매 프레임 재스캔

`waveformSamples: quickRecordBuffer`로 누적 버퍼 전체를 넘기고, `normalizedPeaks`가
`body`(GeometryReader 안) 평가마다 그 전체를 훑는다. 마이크 콜백은 2048샘플마다(약 21회/초)
`quickRecordBuffer`에 append하므로 body가 초당 21번 재평가되고, 그때마다 스캔 길이가 계속 늘어난다.
`@State`의 배열 append도 get→변형→set 경로라 매번 CoW 전체 복사가 일어난다.

재현: 60초까지 녹음하면 마지막 구간에서 버퍼가 2,646,000개(약 10MB)가 되고, 초당 21회 ×
(10MB 복사 + 264만 샘플 abs/max 스캔)이 메인 스레드에서 돈다. 실기기에서 녹음 후반부로 갈수록
파형/타이머 애니메이션이 버벅이고 발열이 생긴다. 주석("최근 오디오 샘플")과 달리 실제로는
전체 녹음을 40칸으로 뭉개고 있어 시각적으로도 후반엔 거의 움직이지 않는다.

수정: 파형용 상태를 누적 버퍼와 분리한다.

```swift
@State var waveformWindow: [Float] = []   // 최근 ~1초만 유지
// 콜백에서:
quickRecordBuffer.append(contentsOf: rawSamples)          // 저장용(뷰에 안 넘김)
waveformWindow.append(contentsOf: rawSamples)
if waveformWindow.count > Int(rawSampleRate) {
    waveformWindow.removeFirst(waveformWindow.count - Int(rawSampleRate))
}
```

누적 버퍼 자체도 뷰가 읽지 않는 값이므로 `@State`가 아니라 참조 타입 박스
(예: `final class RecordingBuffer`)에 두고, `elapsed`만 별도의 가벼운 `@State`로 갱신하면
body 무효화 빈도까지 함께 떨어진다.

---

## [주의] AudioCapture.swift:80-90 — 오디오 렌더 스레드에서 힙 할당 + YIN 전체 실행

이번 커밋에서 바뀐 파일은 아니지만 리뷰 대상 코드가 전적으로 여기에 의존한다.
`installTap` 콜백은 실시간 오디오 스레드에서 실행되는데 그 안에서

1. `Array(UnsafeBufferPointer...)`로 2048개 힙 할당
2. `YINPitchDetector.detectPitch` → `computeDifferenceFunction` /
   `cumulativeMeanNormalizedDifference`가 배열 두 개 추가 할당
3. `DispatchQueue.main.async { }` 클로저 박싱 + 큐 락 획득

이 매 콜백마다 일어난다. malloc과 dispatch 큐 진입은 lock-free가 아니라 우선순위 역전 시
렌더 데드라인(46ms)을 놓칠 수 있다.

재현: 메인 스레드가 무거울 때(위 WORLD 분석, 파형 스캔) 녹음 오디오에 글리치/드롭아웃이 섞인다.
실측하려면 콜백 진입~이탈 시간을 `mach_absolute_time`으로 재서 46ms 대비 분포를 볼 것.

수정: 탭 콜백에서는 미리 할당해둔 링버퍼에 `memcpy`만 하고 세마포어로 워커 스레드를 깨우는
구조로 바꾼다. 최소 조치로도 YIN 호출과 `DispatchQueue.main.async`를 전용 직렬
`DispatchQueue`(`.userInitiated`)로 옮기고, YIN의 작업 배열 두 개를 인스턴스 프로퍼티로
미리 잡아 재사용하면 콜백당 할당 횟수를 0에 가깝게 줄일 수 있다.

---

## [주의] ChordGenerator.swift:218-249 — 방출 점수만 초 단위라 화성 리듬이 노래 빠르기에 좌우된다

`emissionScore`는 `±(1.0~2.0) × duration[초]`인데 `transitionScore`는 무단위 상수
(유지 +3.0, 4/5도 진행 +2.0, 3도 +1.0, 2도 0.0)다. 두 항의 스케일이 묶여 있지 않아서
코드가 바뀌려면 "코드 안 맞는 음의 방출 이득 3·d"가 "전이 손해"를 넘겨야 한다. 즉

- 4/5도 진행: d ≥ 0.33초
- 3도 관계: d ≥ 0.67초
- 2도 관계: d ≥ 1.0초

재현: 8분음표 위주로 빠르게 부른 한 소절(음당 0.2~0.3초)은 어떤 음을 불러도 첫 코드가 끝까지
유지된다 — 133절에서 고치려던 "화음이 고정된 느낌"이 v2에서도 그대로 재현되는 구간이다.
반대로 아주 느리게 부르면 음마다 코드가 바뀌어 v1의 병행진행에 가까워진다.
테스트가 0.02초와 3.0초라는 양 극단만 검증하고 있어 이 중간대가 비어 있다.

수정: 길이를 절대 초가 아니라 시퀀스 내 상대값으로 정규화해 템포 불변으로 만든다.

```swift
// harmonizeSequence에서 한 번 계산해 전달
let medianDuration = melodyNotes.map(\.duration).sorted()[melodyNotes.count / 2]
// emissionScore: duration 대신 (duration / medianDuration)을 쓰고 상한을 둔다
let weight = min(3.0, note.duration / max(medianDuration, 0.05))
```

0.3~0.5초짜리 음 8~12개로 이루어진 현실적인 시퀀스에서 코드가 2~3번 바뀌는지 확인하는
테스트를 함께 추가할 것.

---

## [주의] PracticeView+Capture.swift:412-421 — `toggleVoiceSolo`에만 세대 토큰이 빠져 있다

`startVoiceHarmonyPlayback`은 "stop() 직후 재생 시작 시 이전 완료 콜백이 새 상태를 덮어쓰는"
경쟁을 `voiceHarmonyPlaybackGeneration`으로 막아뒀는데, 같은 구조인 솔로 재생은
`if playingSoloVoice == voice`로만 막는다. 다른 성부로 전환할 때는 이 비교가 우연히 방어가 되지만,
같은 성부를 껐다가 곧바로 다시 켜는 경우엔 값이 다시 A라서 뚫린다.
`AVAudioPlayerNode.stop()`은 스케줄된 버퍼의 완료 핸들러를 호출하고 그게
`DispatchQueue.main.async`로 늦게 도착한다(RecordingPlayer.swift:48-50).

재현: "멜로디" 솔로 재생 → 정지 → 즉시 다시 재생. 첫 재생의 완료 콜백이 두 번째 재생 시작 후에
도착하면 `playingSoloVoice`가 nil이 되어 소리는 나는데 버튼은 ▶︎로 돌아가고, 이후 정지 버튼이
없어 마이크 피드백 가드(`playingSoloVoice == nil`)까지 잘못 열린다.

수정: 화음 쪽과 동일하게 처리한다.

```swift
@State var soloPlaybackGeneration = UUID()
...
let generation = UUID(); soloPlaybackGeneration = generation
try soloVoicePlayer.play(samples: processed, sampleRate: rate) {
    if soloPlaybackGeneration == generation { playingSoloVoice = nil }
}
```

---

## [제안] MelodySession이 관찰 불가능한 참조 타입인데 `body`에서 읽힌다

`MelodySession`은 평범한 `final class`(`@Observable`/`ObservableObject` 아님)인데
`PracticeView+Layout.swift:445`(`melodySession.detectedKey`)와 `PracticeView.swift:196`에서
body가 값을 읽는다. `melodySession.record(...)` / `reset()`은 뷰 갱신을 트리거하지 않고,
지금 화면이 맞게 갱신되는 건 같은 트랜잭션에서 `melodySteps`/`hasCapturedNote`/`quickRecordPhase`가
함께 바뀌기 때문이다. 나중에 조성만 바뀌는 경로가 생기면 조용히 낡은 값이 남는다.

부수적으로 `detectedKey`는 저장 프로퍼티가 아니라 매번 `KeyDetector.detectKey`를 전체 노트에
대해 다시 도는 계산 프로퍼티다(같은 파일 51-53행) — body에서 읽히므로 body 평가 횟수만큼
재계산된다. `suggestedHarmony`(79행)는 더 무거운 Viterbi 전체를 다시 돌리는데
`PracticeView+Scoring.swift:94`의 `.disabled(...)` 안에 들어 있다(지금은 화면에서 빠져 잠복 상태).

수정: `applyQuickRecordResult`에서 `detectedKeyName`을 `@State`로 한 번만 뽑아두거나,
`MelodySession`을 `@Observable`로 바꾸고 `detectedKey`/`suggestedHarmony`를 캐시된
저장 프로퍼티로 만든다.

---

## [제안] ChordGenerator.swift:159-224 — 주석과 구현 불일치(동작 결과는 동일)

`viterbiChordDegrees`의 주석은 "온음계 밖 음은 방출 점수를 모든 후보에 중립(0)으로 둔다"고 하지만
`emissionScore`는 온음계 여부를 보지 않고, 어떤 다이어토닉 트라이어드에도 안 들어가는 음이면
`-1.0 * duration`을 돌려준다. 그 값이 그 스텝의 모든 후보에 똑같이 더해지므로 argmax는 바뀌지 않아
실제 선택 결과는 주석대로다. 나중에 방출 점수를 후보별로 다르게 만드는 순간(예: 근음 가중치 추가)
조용히 의미가 달라지므로, 주석을 코드에 맞추거나 `isOnScale`을 `emissionScore`에 명시적으로
넘겨 0을 반환하게 하는 편이 안전하다.

---

## [제안] PracticeView.swift:65·125·140·159-161 — 참조 타입을 struct View의 `let` 프로퍼티로 보유

`audioCapture` / `voiceHarmonyPlayer` / `soloVoicePlayer` / `startingNotePlayer` /
`melodySession` / `pitchSmoother`가 모두 `let x = X()` 형태라, `PracticeView` 구조체가 다시
만들어질 때마다 새 인스턴스(AVAudioEngine 포함)가 생성된다. 지금은 `RootTabView`가 상태를 하나도
갖지 않아 `PracticeView()`가 사실상 한 번만 초기화되므로 실제 버그로 드러나지 않지만,
`RootTabView`에 상태가 하나라도 추가되는 순간 "재생 중이던 엔진과 stop()을 호출하는 엔진이 서로
다른 인스턴스"가 되어 마이크가 안 꺼지는 버그가 생긴다.

수정: 오디오 인스턴스들을 하나의 `@Observable` 엔진 객체로 묶어 `@State`로 보유한다.

---

## [제안] 접근성 — 장식용 애니메이션이 VoiceOver에 노출된다

`WaveformView`(막대 40개)와 `RecordingHalo`는 정보를 전달하지 않는 장식인데 접근성 트리에 남는다.
`.accessibilityHidden(true)`를 붙이고, 녹음 상태는 이미 있는 타이머 텍스트에
`.accessibilityLabel("녹음 중, \(formattedTime(elapsed)) 경과")`로 묶으면 스와이프 이동이 짧아진다.

아이콘 전용 버튼들은 `accessibilityLabel`이 전부 붙어 있고 탭 영역도 44×44로 확보돼 있어 문제 없음.
