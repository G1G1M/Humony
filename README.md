# HarmonyUp (하모니업)

멜로디를 녹음하면 음표별로 인식해서 악보로 보여주는 iOS 앱. **2026-08-20부로 화음 생성/재생 기능은 전부 제거하고, 멜로디 인식(녹음 → 음표 추출 → 악보 표시)만 남긴 상태다** — 화음 소리(목소리 피치시프트/합성음)가 여러 라운드를 거쳐도 "이상하게 들린다"는 문제를 못 풀어서, 멜로디 인식 자체를 먼저 확실히 다진 뒤 처음부터 다시 설계하기로 했다. 원래 구상(화음 생성+따라 부르기 채점)은 [`docs/prd.md`](docs/prd.md) 참고 — 관련 코드(`ChordGenerator`, 채점 파일들)는 지우지 않고 남겨뒀다(아래 "보관 중인 코드" 참고).

전체 배경(문제의식, 경쟁 분석, 페르소나 등)은 [`docs/prd.md`](docs/prd.md), 개발 지침은 [`CLAUDE.md`](CLAUDE.md) 참고. 신호처리 개념 학습 노트는 [`docs/CONCEPTS.md`](docs/CONCEPTS.md)에 계속 정리 중.

## 기술 스택

- Swift, SwiftUI
- AVAudioEngine / AVAudioSession — 마이크 캡처
- YIN 알고리즘 직접 구현 (Accelerate/vDSP) — 서드파티 피치 검출 라이브러리 미사용
- 서버 없음 — 전 과정 온디바이스
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml`로 `.xcodeproj` 생성 (커밋 대상 아님, `xcodegen generate`로 재생성)
- [Pretendard](https://github.com/orioncactus/pretendard) (SIL OFL 1.1) — 앱 전역 폰트, `HarmonyUp/Sources/Resources/Fonts/`에 4개 굵기 번들

## 진행 상황

전체 체크리스트는 [`docs/PROGRESS.md`](docs/PROGRESS.md) 참고. 최근 작업: 화음 API(피치시프트 3종+합성음+WORLD+VoiceDoubler+VoiceClipPlayer 등) 전체 제거, 멜로디 인식/악보 표시만 남김(116절).

## 구성 요소 (`HarmonyUp/Sources/PitchEngine/`) — 지금 쓰이는 멜로디 인식 파이프라인

| 파일 | 역할 |
|---|---|
| `NoteNameConverter` | Hz ↔ MIDI 노트/음이름/cent 변환 |
| `YINPitchDetector` | 자기상관 기반 YIN 기본 주파수(F0) 검출 |
| `VoiceActivityDetector` | 에너지 임계값 기반 무음 구간 필터링 |
| `AudioCapture` | AVAudioEngine 마이크 캡처 + 파이프라인 연결 |
| `KeyDetector` | pitch-class 히스토그램 기반 조성 판별 (Temperley 1999 key profile) — 악보에 감지된 조성 표시용 |
| `MelodySession` | 프레임별 감지 결과를 누적해 KeyDetector에 연결 |
| `TonePlayer` | 지정 주파수 톤 재생(배음+envelope) — 녹음 전 "첫음 잡기" 참고음 재생에 사용(66절) |
| `PitchSmoother` | MIDI 노트(로그 스케일) 기준 EMA로 비브라토·흔들림 완화 |
| `AudioGain` | 녹음 종료 직후 분석 전에 거는 러프니스 정규화(기기별 마이크 게인 차이 보정) |
| `MelodySegmenter` | 녹음 전체를 배치로 분석해 음표(음높이+시작시간+길이) 목록으로 잘라내기 |
| `RecordingAnalyzer` | `MelodySegmenter` 출력을 `KeyDetector`에 연결해 `MelodyStep` 배열로 변환 |
| `RhythmQuantizer` | 실제 음 길이(초)를 중앙값 대비 상대적으로 비교해 VexFlow 음표 종류(8분/4분/점4분/2분)와 마디 구성으로 변환 |
| `VexFlowScoreView` | `WKWebView`로 로컬 VexFlow(MIT, 벤더링)를 로드해 멜로디 오선보를 그리는 브릿지 뷰 |
| `SheetMusicFullScreenView` | `VexFlowScoreView`를 전체화면으로 크게 보여주는 렌더링 검증용 화면 |

## 보관 중인 코드(현재 미사용, 나중에 재사용 예정)

화음/채점 관련 코드는 지우지 않고 남겨뒀다 — 다시 붙일 때 참고하거나 그대로 재사용할 수 있게.

- `ChordGenerator` — 멜로디 음 하나하나마다 독립적으로 그 음 자신을 근음 삼아 다이어토닉 트라이어드(베이스/3도/5도)를 계산하는 화성 이론 로직. 지금은 아무 데서도 안 부름.
- `PitchScorer`/`PracticeSummary`/`PracticeAttempt`(SwiftData)/`PracticeView+Scoring.swift`/`HistoryView` — "따라 부르기 채점"과 기록 탭. 화음 목표음이 없으면 채점할 대상이 없어서 UI에서 뺐다(`PracticeView+Layout.swift`가 더 이상 `scoringCard`를 안 부름).
- 목소리 피치시프트(WSOLA/PSOLA/WORLD 3종), 합성음(`ToneSynthesizer`), 화음 트랙 조립(`HarmonyTrackBuilder`/`SynthesizedHarmonyTrackBuilder`), 다중 트랙 재생(`VoiceClipPlayer`), 보컬 더블링(`VoiceDoubler`), WORLD 보코더(`HarmonyUp/ThirdParty/World/`)는 **git 히스토리에서 완전히 삭제**했다(커밋 이전으로 되돌리려면 116절 커밋 직전을 참고) — 이 파일들은 여러 번 되살렸다 지웠다 한 이력이 있어서(112~115절), 다시 필요하면 git log에서 찾아서 복원하면 된다.

## 개발

```bash
xcodegen generate   # project.yml -> HarmonyUp.xcodeproj
xcodebuild -project HarmonyUp.xcodeproj -scheme HarmonyUp \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3),OS=26.3.1' test
```
