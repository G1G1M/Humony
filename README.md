# 휴모니 (Humony)

**멜로디를 부르면 화음을 만들어주고, 그 화음을 따라 부르며 연습하는 iOS 앱.**

혼자서는 화음 파트를 연습할 방법이 마땅치 않습니다. 이어 트레이닝 앱은 듣고 맞히기만 하고,
마이크 피치 앱은 화음을 만들어주지 않아요. 그 사이를 메우는 것이 목표입니다.

## 무엇을 하나

| | |
|---|---|
| **녹음 → 채보** | 한 소절을 부르면 음표별 음높이·시작시각·길이를 뽑아냅니다 |
| **악보와 대조** | 부른 뒤 악보를 붙이면 채보를 그 악보에 맞춰 다듬습니다. 악보는 **사진으로 찍어도** 되고 MusicXML(`.musicxml`/`.xml`/`.mxl`)·MIDI 파일이어도 됩니다 |
| **화음 생성** | 조성을 판별하고, 노트 시퀀스 전체의 문맥을 보고(HMM + Viterbi) 베이스·3도·5도를 얹습니다 |
| **내 목소리로 듣기** | 만들어진 화음을 사용자 본인 목소리로 재생합니다 |
| **악보** | 멜로디와 3성부를 4단 오선보로 그립니다 |
| **따라 부르기 채점** | 성부를 골라 듣고 → 소리를 끄고 → 한 소절을 불러 정확도를 채점합니다 |
| **기록** | 연습을 녹음 세션 단위로 쌓고, 그때의 악보를 다시 볼 수 있습니다 |

## 기술 스택

- **Swift / SwiftUI**, SwiftData
- **AVAudioEngine · AVAudioSession** — 오디오 입출력
- **Accelerate/vDSP** — 피치 검출(YIN)은 직접 구현합니다. 학습이 목적이라 서드파티 피치
  라이브러리는 쓰지 않아요
- [WORLD](https://github.com/mmorise/World) (modified-BSD) — 포먼트를 보존하는 목소리 피치 시프트
- [VexFlow](https://www.vexflow.com) (MIT) — 오선보 렌더링, 로컬에 번들
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml`로 프로젝트 생성
- [Pretendard](https://github.com/orioncactus/pretendard) (SIL OFL 1.1) — 앱 폰트

**서버가 없습니다.** 녹음부터 채점까지 전 과정이 기기 안에서 처리됩니다.

## 구조

```
Humony/Sources/
├─ App/        진입점, 번들 리소스(폰트·VexFlow)
├─ Core/       디자인 시스템, 기기 I/O 래퍼, 공용 변환
├─ Data/       SwiftData 모델 (세션·채점 시도)
├─ Domain/     Pitch · Melody · Harmony · Scoring
└─ Features/   Practice · History (기능별 Model/View)
```

기능 우선 배치입니다 — 여러 기능이 공유하는 것만 `Core`/`Domain`으로 올리고, 기능 전용 로직은
그 기능 폴더의 `Model/`에 둡니다. 자세한 규약은 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

### 파이프라인

```
마이크 → 녹음 → 음표 추출 ─(악보가 있으면 대조·교정)→ 조성 판별 → 화음 생성 ─┬→ 악보 (4성부)
                                                                            ├→ 재생 (내 목소리 화음)
                                                                            └→ 채점 → 기록
```

악보는 선택입니다 — 붙이지 않으면 위 흐름이 그대로 돌고, 붙였는데 잘 맞지 않으면 교정을
포기하고 부른 그대로 갑니다.

| 갈래 | 하는 일 | 핵심 타입 |
|---|---|---|
| `Domain/Pitch` | 기본 주파수 검출, 무음 필터, 음정 판정 | `YINPitchDetector`, `PitchScorer` |
| `Domain/Melody` | 녹음을 음표로 자르기, 조성 판별, 템포 추정과 리듬 표기 | `MelodySegmenter`, `KeyDetector`, `TempoEstimator` |
| `Domain/Harmony` | 코드 진행 선택, 피치 시프트, 성부 트랙 합성 | `ChordGenerator`, `PitchShifterWorld`, `VoiceHarmonyTrackBuilder` |
| `Domain/Score` | 악보를 읽어 채보의 "정답지"로 쓰기 — 사진 해독, 조옮김 추정, 정렬·교정 | `SheetMusicImageReader`, `TranspositionEstimator`, `MelodyScoreCorrector` |
| `Domain/Scoring` | 부른 음 시퀀스를 목표 성부와 정렬해 채점 | `HarmonyPracticeScorer` |

`Domain/`은 전부 순수 함수로 두고 유닛테스트로 고정합니다. 오디오 품질 문제는 실기기 청취로만
드러나는 경우가 많아서, 테스트 가능한 형태를 유지하는 것이 특히 중요해요.

## 개발

```bash
xcodegen generate

xcodebuild -project Humony.xcodeproj -scheme Humony \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3)' test
```

유닛테스트 409개. `.xcodeproj`는 커밋하지 않고 `project.yml`에서 생성합니다.

## 문서

| 문서 | 내용 |
|---|---|
| [`docs/PROGRESS.md`](docs/PROGRESS.md) | 진행 상황 체크리스트 |
| [`docs/CONCEPTS.md`](docs/CONCEPTS.md) | 신호처리·설계 결정 히스토리 — 왜 그렇게 했는지 |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 파일 구조 규약 |
| [`docs/prd.md`](docs/prd.md) | 제품 배경 (문제의식, 페르소나) |
