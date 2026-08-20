# HarmonyUp (하모니업)

멜로디를 노래하면 화음을 자동으로 찾아주고, 그 화음을 따라 부르며 실시간으로 채점받는 iOS 화음 훈련 앱.

전체 배경(문제의식, 경쟁 분석, 페르소나 등)은 [`docs/prd.md`](docs/prd.md), 개발 지침은 [`CLAUDE.md`](CLAUDE.md) 참고. 신호처리 개념 학습 노트는 [`docs/CONCEPTS.md`](docs/CONCEPTS.md)에 계속 정리 중.

## 기술 스택

- Swift, SwiftUI
- AVAudioEngine / AVAudioSession — 마이크 캡처
- YIN 알고리즘 직접 구현 (Accelerate/vDSP) — 서드파티 피치 검출 라이브러리 미사용
- 서버 없음 — 전 과정 온디바이스
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml`로 `.xcodeproj` 생성 (커밋 대상 아님, `xcodegen generate`로 재생성)
- [Pretendard](https://github.com/orioncactus/pretendard) (SIL OFL 1.1) — 앱 전역 폰트, `HarmonyUp/Sources/Resources/Fonts/`에 4개 굵기 번들

## 진행 상황

전체 체크리스트는 [`docs/PROGRESS.md`](docs/PROGRESS.md) 참고. 최근 작업: 화음 재생이 성부별로 다른 오디오 노드에서 시작돼 밀리던 문제를 단일 노드 믹스 재생으로 수정(109절).

## 구성 요소 (`HarmonyUp/Sources/PitchEngine/`)

| 파일 | 역할 |
|---|---|
| `NoteNameConverter` | Hz ↔ MIDI 노트/음이름/cent 변환 |
| `YINPitchDetector` | 자기상관 기반 YIN 기본 주파수(F0) 검출 |
| `VoiceActivityDetector` | 에너지 임계값 기반 무음 구간 필터링 |
| `AudioCapture` | AVAudioEngine 마이크 캡처 + 파이프라인 연결 |
| `KeyDetector` | pitch-class 히스토그램 기반 조성 판별 (Temperley 1999 key profile) |
| `ChordGenerator` | 멜로디 노트 시퀀스 전체에 HMM+Viterbi로 다이어토닉 코드 진행을 붙여 베이스/3도/5도 생성 |
| `MelodySession` | 프레임별 감지 결과를 누적해 KeyDetector/ChordGenerator에 연결 |
| `TonePlayer` | 지정 주파수 톤 재생(배음+envelope) — 녹음 전 "첫음 잡기" 참고음 재생에 사용(66절) |
| `PitchScorer` | 목표 주파수 대비 사용자 음정의 cent 편차 채점 |
| `PitchSmoother` | MIDI 노트(로그 스케일) 기준 EMA로 비브라토·흔들림 완화 |
| `PracticeSummary` | 채점 시도(Score 배열)를 정확도/평균편차 요약 통계로 압축 |
| `PracticeAttempt` | SwiftData 모델 — 채점 시도 요약을 세션 기록으로 저장 |
| `PitchShifter` | 피치 시프팅(길이 유지, 피치만 이동) — [WORLD](https://github.com/mmorise/World)(BSD, `HarmonyUp/ThirdParty/World/`) 호출로 포먼트 보존 |
| `VoiceClipPlayer` | 여러 오디오 트랙([Float])을 각자 다른 pan으로 동시 재생, 공유 `AVAudioUnitReverb`로 공간감 부여 |
| `AudioGain` | 재생 전 샘플 자체를 스케일업하는 피크/러프니스 정규화 |
| `VoiceDoubler` | 성부별 지연+미세 디튠 복사본을 섞는 보컬 더블링(ADT) |
| `MelodySegmenter` | 녹음 전체를 배치로 분석해 음표(음높이+시작시간+길이) 목록으로 잘라내기 |
| `RecordingAnalyzer` | `MelodySegmenter` 출력을 `KeyDetector`/`ChordGenerator`에 연결해 기존 `MelodyStep` 배열로 변환 |
| `RhythmQuantizer` | 실제 음 길이(초)를 중앙값 대비 상대적으로 비교해 VexFlow 음표 종류(8분/4분/점4분/2분)와 마디 구성으로 변환 |
| `VexFlowScoreView` | `WKWebView`로 로컬 VexFlow(MIT, 벤더링)를 로드해 성부별 오선보를 그리는 브릿지 뷰 |
| `SheetMusicFullScreenView` | `VexFlowScoreView`를 전체화면으로 크게 보여주는 렌더링 검증용 화면(아이폰 컴팩트 레이아웃 전용) |

## 개발

```bash
xcodegen generate   # project.yml -> HarmonyUp.xcodeproj
xcodebuild -project HarmonyUp.xcodeproj -scheme HarmonyUp \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3),OS=26.3.1' test
```
