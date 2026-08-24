# HarmonyUp (하모니업)

멜로디를 녹음하면 음표별로 인식해서 악보로 보여주고, 그 위에 화음(베이스/3도/5도)을 얹어 들려주는 iOS 앱. 2026-08-20에 화음 생성/재생 기능을 한 번 전부 제거하고 멜로디 인식(녹음 → 음표 추출 → 악보 표시)부터 다시 다진 뒤(실기기 다회 재검증 완료), 화음을 처음부터 다시 쌓았다 — 합성음(순수 사인파)으로 화음 선택/타이밍/재생 구조부터 변수 격리해 검증(120~122절)한 뒤, 목소리 피치시프트를 얹는 2단계에서 WSOLA(123절, "어색함")를 거쳐 **WORLD 보코더로 단계별 재통합(124~126절)해 실기기에서 "훨씬 자연스럽다"는 확인(127절)을 받았다**. 원래 구상(목소리 화음+따라 부르기 채점)은 [`docs/prd.md`](docs/prd.md) 참고 — 채점 관련 코드(`PitchScorer`, `PracticeAttempt` 등)는 여전히 UI에서 뺀 채 남겨뒀다(아래 "보관 중인 코드" 참고).

전체 배경(문제의식, 경쟁 분석, 페르소나 등)은 [`docs/prd.md`](docs/prd.md), 개발 지침은 [`CLAUDE.md`](CLAUDE.md) 참고. 신호처리 개념 학습 노트는 [`docs/CONCEPTS.md`](docs/CONCEPTS.md)에 계속 정리 중.

## 기술 스택

- Swift, SwiftUI
- AVAudioEngine / AVAudioSession — 마이크 캡처
- YIN 알고리즘 직접 구현 (Accelerate/vDSP) — 서드파티 피치 검출 라이브러리 미사용
- 서버 없음 — 전 과정 온디바이스
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml`로 `.xcodeproj` 생성 (커밋 대상 아님, `xcodegen generate`로 재생성)
- [Pretendard](https://github.com/orioncactus/pretendard) (SIL OFL 1.1) — 앱 전역 폰트, `HarmonyUp/Sources/App/Resource/Fonts/`에 4개 굵기 번들

## 진행 상황

전체 체크리스트는 [`docs/PROGRESS.md`](docs/PROGRESS.md) 참고. 최근 작업: 화음 재설계 1단계(120절, 합성음) → 크로스페이드/지지직 수정(121~122절) → 목소리 피치시프트 2단계, WSOLA 시도했으나 "어색함"(123절) → 웹서비스/오픈소스 라이선스 조사 → WORLD 보코더를 3단계로 나눠 복원(124~126절)하고 실기기에서 "훨씬 자연스럽다" 확인(127절) → 멜로디+화음 자연스러움 7단계 다듬기(128절, "잘 작동해"로 마무리) → "전체 한 번 분석+F0곡선 재합성" 구조 개선 1~3단계(129~131절, "전보다 자연스러워서 좋다"로 이어붙임 티 감소 확인) → 보코더 음질(기계음) 개선 1차 실험(132절: WORLD D4C threshold 0.5로 확정, "나쁘지 않아") → "화음이 고정된 느낌"을 화성 모델(v1, 멜로디 음마다 새 근음)의 병행진행 한계로 진단(133절) → 화성 모델 v2(HMM+Viterbi, 51절) 재구현 완료(134절: `ChordGenerator` 내부를 방출점수+전이점수+Viterbi DP로 교체) → **재생 조작부 UI 재설계**(135절: Claude Design 하이파이 목업으로 방향을 잡은 뒤 실제 코드 반영 — 버튼 11개를 "내 목소리로 화음 듣기" 하나 + 항상 펼쳐진 성부별 4행으로 정리, 아이패드 2단 스플릿 정렬을 픽셀 단위로 3라운드 다듬음, 녹음 애니메이션 개선) → **악보 4성부 복원 + 마디 4박 정합**(136절 1단계: 악보 API 대안 조사 후 VexFlow 유지로 결론, `RhythmQuantizer.measureBreaks`가 4/4 표기에 5박을 담던 버그 수정, 페이로드 조립을 순수 타입 `VexFlowScorePayload`로 분리해 "전 성부 음 개수 동일 + 마디 구성 공유" 불변식을 테스트로 고정, 멜로디/5도/3도/베이스 4행 생성) → **채점 재설계**(136절 2단계: 성부를 먼저 들어보고 → 소리 끄고 → 한 소절을 통째로 불러 배치 채점, `HarmonyPracticeScorer` 편집거리 정렬로 누락/추가까지 집계, 재생과 마이크를 시간상 분리해 피드백 루프 문제를 원천 차단) → **기록 탭 세션 단위 개편**(136절 3단계: 녹음 하나가 세션이 되고 그 아래 성부별 시도가 쌓인다, 오디오 없이 그때의 악보를 다시 보기, 연속 연습 일수·자주 틀리는 음·음정 편향을 `PracticeStatistics` 순수 함수로) → **템포 추정**(139절: 음의 길이가 아니라 시작 간격에서 실제 박을 찾아 음표 길이를 정한다 — 중앙값 방식은 8분음표가 많은 노래에서 전부 한 단계씩 밀려 표기됐다, 자유 리듬이면 예전 방식으로 폴백). → **성부 순서 통일**(140절: 조작부와 악보가 정반대였던 성부 순서를 악보 기준(음높이 내림차순)으로 맞추고, 순서를 `ChordGenerator.Interval.displayOrder` 한 곳에만 둬서 다시 갈리지 않게). 유닛테스트 220개 통과. **다음**: 실기기 확인(악보 4성부 + 채점 흐름 + 기록 탭 + 리듬 표기) → 채보 정확도 튜닝(실기기 로그 기반) → 음표 표기를 발성 길이가 아닌 간격 기준으로(쉼표 포함).

## 구성 요소

파일 구조는 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) 참고 — 2026-08-24에 junCook(ValleyRisk)의
MVVM 레이아웃(App/Core/Data/Domain/Features)으로 옮겼다. 기능 우선 배치라, 여러 기능이 공유하는
것만 Core/Domain으로 올리고 기능 전용 로직은 그 기능 폴더의 `Model/`에 둔다.

### `Domain/Pitch` — 음높이 검출과 판정

| 파일 | 역할 |
|---|---|
| `YINPitchDetector` | 자기상관 기반 YIN 기본 주파수(F0) 검출 |
| `VoiceActivityDetector` | 에너지 임계값 기반 무음 구간 필터링 |
| `PitchSmoother` | MIDI 노트(로그 스케일) 기준 EMA로 비브라토·흔들림 완화 |
| `PitchScorer` | 목표 주파수 대비 cent 편차와 허용 오차(35cent) 판정 |

### `Domain/Melody` — 채보(녹음 → 음표 시퀀스)

| 파일 | 역할 |
|---|---|
| `MelodySegmenter` | 녹음 전체를 배치로 분석해 음표(음높이+시작시각+길이) 목록으로 잘라내기 |
| `KeyDetector` | pitch-class 히스토그램 기반 조성 판별 (Temperley 1999 key profile) |
| `MelodySession` | 프레임별 감지 결과를 누적해 `KeyDetector`에 연결 |
| `RecordingAnalyzer` | `MelodySegmenter` 출력을 `KeyDetector`+`ChordGenerator`에 연결해 화음까지 채워진 `MelodyStep` 배열로 |
| `TempoEstimator` | 음의 시작 간격에서 실제 박(BPM)을 추정 — 139절 |
| `RhythmQuantizer` | 음 길이를 VexFlow 음표 종류(8분/4분/점4분/2분)와 마디 구성으로 변환. 박을 추정하면 그 그리드로, 못 하면 중앙값 기준으로 폴백 |
| `MelodyStep` | 확정된 멜로디 음 하나 + 그 위에 쌓은 3성부(화면과 오디오가 공유하는 데이터) |

### `Domain/Harmony` — 화음 생성과 오디오 합성

| 파일 | 역할 |
|---|---|
| `ChordGenerator` | 조성 안에서 노트 시퀀스 전체의 문맥을 보고(HMM+Viterbi, v2 134절) 다이어토닉 코드를 배정해 베이스/3도/5도를 만든다 |
| `PitchShifterWorld` | WORLD 보코더(modified-BSD, `HarmonyUp/ThirdParty/World/`) C 브릿지 래퍼 — F0와 스펙트럼 포락선을 분리 분석해 포먼트를 보존한 채 피치만 옮김 |
| `VoiceHarmonyTrackBuilder` | 원본 녹음에서 F0 곡선을 조립해 한 번에 재합성하는 방식으로 "내 목소리로 화음" 트랙 생성(130절) |
| `ToneSynthesizer` / `SynthesizedHarmonyTrackBuilder` | 순수 사인파 합성 버전(120~122절) — 지금 UI에서는 안 쓰지만 변수 격리 검증용으로 남겨둠 |
| `PitchShifter` | WSOLA 피치시프트(123절) — WORLD로 교체됐지만 비교용으로 남겨둠 |
| `AudioGain` | 러프니스 정규화(기기별 마이크 게인 차이 보정) + 페이드/합산 |

### `Domain/Scoring` — 채점

| 파일 | 역할 |
|---|---|
| `HarmonyPracticeScorer` | 따라 부른 음 시퀀스를 목표 성부와 편집거리로 정렬해 채점 — 누락·추가까지 집계(137절) |
| `PracticeSummary` | 채점 샘플을 요약 통계로 압축 |

### `Core` — 전 계층이 공유

| 파일 | 역할 |
|---|---|
| `Core/Util/NoteNameConverter` | Hz ↔ MIDI 노트/음이름/cent 변환 (`Int.mod` 확장 포함) |
| `Core/Local/AudioCapture` | AVAudioEngine 마이크 캡처 + 파이프라인 연결 |
| `Core/Local/RecordingPlayer` | 모노 `[Float]` 버퍼 하나를 트는 범용 재생기 |
| `Core/Local/TonePlayer` | 지정 주파수 톤 실시간 재생 — 녹음 전 "첫음 잡기" 참고음 전용 |
| `Core/DesignSystem/Theme` | 색·타이포·간격 토큰과 글래스 표면 스타일 |

### `Features` — 화면

| 파일 | 역할 |
|---|---|
| `Practice/Model/VexFlowScorePayload` | `MelodyStep` 배열을 VexFlow 페이로드로 조립(4성부, 마디 구성 공유) |
| `Practice/View/VexFlowScoreView` | `WKWebView`로 로컬 VexFlow(MIT, 벤더링)를 로드해 4성부 오선보를 그리는 브릿지 뷰 |
| `Practice/View/PracticeView(+Layout/+Capture/+Scoring)` | 녹음 → 악보 → 화음 재생 → 따라 부르기 채점까지 연습 탭 전체 |
| `History/Model/PracticeStatistics` | 연속 연습 일수·자주 틀리는 음·음정 편향 계산(순수 함수) |
| `History/View/HistoryView`, `SessionDetailView` | 세션 단위 기록 목록과, 그때의 악보를 다시 보는 상세 |

### `Data/DB`

| 파일 | 역할 |
|---|---|
| `PracticeSession` | 녹음 한 번 — 조성·멜로디·화음 스냅샷(오디오는 저장하지 않는다) |
| `PracticeAttempt` | 그 세션의 성부별 채점 시도 — 정확도·편차·벗어난 음의 정체 |

## 개발

```bash
xcodegen generate   # project.yml -> HarmonyUp.xcodeproj
xcodebuild -project HarmonyUp.xcodeproj -scheme HarmonyUp \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3),OS=26.3.1' test
```
