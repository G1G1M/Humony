# HarmonyUp (하모니업)

멜로디를 녹음하면 음표별로 인식해서 악보로 보여주고, 그 위에 화음(베이스/3도/5도)을 얹어 들려주는 iOS 앱. 2026-08-20에 화음 생성/재생 기능을 한 번 전부 제거하고 멜로디 인식(녹음 → 음표 추출 → 악보 표시)부터 다시 다진 뒤(실기기 다회 재검증 완료), **화음을 처음부터 다시 쌓는 중이다** — 목소리 피치시프트가 여러 라운드를 거쳐도 "이상하게 들린다"는 문제를 못 풀었던 전례가 있어, 이번엔 합성음(순수 사인파)부터 시작해 "화음 선택/타이밍이 맞는지"를 변수 격리해서 검증하고 있다. 원래 구상(목소리 화음+따라 부르기 채점)은 [`docs/prd.md`](docs/prd.md) 참고 — 채점 관련 코드(`PitchScorer`, `PracticeAttempt` 등)는 여전히 UI에서 뺀 채 남겨뒀다(아래 "보관 중인 코드" 참고).

전체 배경(문제의식, 경쟁 분석, 페르소나 등)은 [`docs/prd.md`](docs/prd.md), 개발 지침은 [`CLAUDE.md`](CLAUDE.md) 참고. 신호처리 개념 학습 노트는 [`docs/CONCEPTS.md`](docs/CONCEPTS.md)에 계속 정리 중.

## 기술 스택

- Swift, SwiftUI
- AVAudioEngine / AVAudioSession — 마이크 캡처
- YIN 알고리즘 직접 구현 (Accelerate/vDSP) — 서드파티 피치 검출 라이브러리 미사용
- 서버 없음 — 전 과정 온디바이스
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml`로 `.xcodeproj` 생성 (커밋 대상 아님, `xcodegen generate`로 재생성)
- [Pretendard](https://github.com/orioncactus/pretendard) (SIL OFL 1.1) — 앱 전역 폰트, `HarmonyUp/Sources/Resources/Fonts/`에 4개 굵기 번들

## 진행 상황

전체 체크리스트는 [`docs/PROGRESS.md`](docs/PROGRESS.md) 참고. 최근 작업: 화음 재설계 1단계(120절, `ToneSynthesizer`+`SynthesizedHarmonyTrackBuilder`) → 실기기 검증 중 "따다다닥" 끊김 발견, 진짜 크로스페이드로 수정(121절) → 잔여 "지지직"을 짧은 음 램프 중첩 방지+화음 재생 음량 조정으로 개선(122절). 다음은 목소리 기반 화음("내 목소리로 화음 만들기") 단계로 넘어갈지 논의 중.

## 구성 요소 (`HarmonyUp/Sources/PitchEngine/`)

| 파일 | 역할 |
|---|---|
| `NoteNameConverter` | Hz ↔ MIDI 노트/음이름/cent 변환 |
| `YINPitchDetector` | 자기상관 기반 YIN 기본 주파수(F0) 검출 |
| `VoiceActivityDetector` | 에너지 임계값 기반 무음 구간 필터링 |
| `AudioCapture` | AVAudioEngine 마이크 캡처 + 파이프라인 연결 |
| `KeyDetector` | pitch-class 히스토그램 기반 조성 판별 (Temperley 1999 key profile) — 악보에 감지된 조성 표시용 |
| `MelodySession` | 프레임별 감지 결과를 누적해 KeyDetector에 연결 |
| `ChordGenerator` | 멜로디 음 하나하나마다 독립적으로 그 음 자신을 근음 삼아 다이어토닉 트라이어드(베이스/3도/5도)를 계산하는 화성 이론 로직(v1, 101절) |
| `ToneSynthesizer` | 순수 사인파를 오프라인(배열)으로 합성 — 화음 재설계 1단계(120절), 목소리 피치시프트 배제 |
| `SynthesizedHarmonyTrackBuilder` | 멜로디 스텝 시퀀스를 원본 녹음과 같은 길이의 트랙으로(멜로디/베이스/3도/5도 전부 `ToneSynthesizer`로 합성, 120절) |
| `TonePlayer` | 지정 주파수 톤을 실시간 재생(배음+envelope) — 녹음 전 "첫음 잡기" 참고음 전용(66절) |
| `RecordingPlayer` | 모노 `[Float]` 버퍼 하나를 트는 범용 재생기 — "녹음 다시 듣기"(117절)와 "화음 듣기"(120절) 둘 다 이 타입의 별개 인스턴스를 쓴다 |
| `PitchSmoother` | MIDI 노트(로그 스케일) 기준 EMA로 비브라토·흔들림 완화 |
| `AudioGain` | 러프니스 정규화(기기별 마이크 게인 차이 보정) + 화음 트랙용 페이드/합산(`applyFadeInOut`/`mix`, 120절) |
| `MelodySegmenter` | 녹음 전체를 배치로 분석해 음표(음높이+시작시간+길이) 목록으로 잘라내기 |
| `RecordingAnalyzer` | `MelodySegmenter` 출력을 `KeyDetector`+`ChordGenerator`에 연결해 화음까지 채워진 `MelodyStep` 배열로 변환 |
| `RhythmQuantizer` | 실제 음 길이(초)를 중앙값 대비 상대적으로 비교해 VexFlow 음표 종류(8분/4분/점4분/2분)와 마디 구성으로 변환 |
| `VexFlowScoreView` | `WKWebView`로 로컬 VexFlow(MIT, 벤더링)를 로드해 멜로디 오선보를 그리는 브릿지 뷰 |
| `SheetMusicFullScreenView` | `VexFlowScoreView`를 전체화면으로 크게 보여주는 렌더링 검증용 화면 |

## 보관 중인 코드(현재 미사용, 나중에 재사용 예정)

채점 관련 코드는 지우지 않고 남겨뒀다 — 화음 재생이 다시 자리잡은 뒤 순서를 다시 논의할 대상.

- `PitchScorer`/`PracticeSummary`/`PracticeAttempt`(SwiftData)/`PracticeView+Scoring.swift`/`HistoryView` — "따라 부르기 채점"과 기록 탭. 화음이 아직 목소리 기반이 아니라 목표음으로 쓰기엔 이르다고 판단해 UI에서 뺐다(`PracticeView+Layout.swift`가 더 이상 `scoringCard`를 안 부름).
- 목소리 피치시프트(WSOLA/PSOLA/WORLD 3종), 화음 트랙 조립(`HarmonyTrackBuilder`, 목소리 버전), 다중 트랙 재생(`VoiceClipPlayer`), 보컬 더블링(`VoiceDoubler`), WORLD 보코더(`HarmonyUp/ThirdParty/World/`)는 **git 히스토리에서 완전히 삭제**했다(116절 커밋 직전 참고) — 여러 번 되살렸다 지웠다 한 이력이 있어서(112~115절), 다시 필요하면 git log에서 찾아 복원하면 된다. `ToneSynthesizer`/`SynthesizedHarmonyTrackBuilder`는 120절에서 다시 살아나 위 표에 있다.

## 개발

```bash
xcodegen generate   # project.yml -> HarmonyUp.xcodeproj
xcodebuild -project HarmonyUp.xcodeproj -scheme HarmonyUp \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3),OS=26.3.1' test
```
