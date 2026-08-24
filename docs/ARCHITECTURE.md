# 파일 구조 — junCook(ValleyRisk) MVVM 레이아웃 적용

2026-08-24, "`Junction2026-team15-junCook` 프로젝트의 파일구조(MVVM)를 우리 앱에도 적용해달라"는
요청으로 정한 목표 구조다. 실제 이동은 `scripts/apply-mvvm-structure.sh`가 수행한다.

## junCook의 규약

```
ValleyRisk/
├─ App/       Source(진입점) · Resource(에셋·폰트)
├─ Core/      DesignSystem · Local(기기 서비스) · Remote(네트워크) · Util
├─ Data/      API/<서비스별> · DB
├─ Domain/    <영역>/  — 여러 기능이 공유하는 모델
└─ Features/  <기능>/{Model, View, ViewModel}
```

핵심은 **기능 우선(feature-first)** 이다. 기능 폴더 안에 Model·View·ViewModel을 두고,
여러 기능이 공유하는 것만 Core/Data/Domain으로 올린다. 기능 전용 계산 로직도 Domain이 아니라
그 기능의 `Model/`에 둔다(junCook에서 `RiskIndexCalculator`, `DashboardSummaryMapper`가
`Features/Dashboard/Model/`에 있는 것이 그 예다).

## HarmonyUp 대응표

```
HarmonyUp/Sources/
├─ App/
│  ├─ Source/       HarmonyUpApp.swift, Info.plist, HarmonyUp-Bridging-Header.h
│  └─ Resource/     Fonts/, VexFlowScore/
├─ Core/
│  ├─ DesignSystem/ Theme, WaveformView, LoadingIndicators, PitchMeterView
│  ├─ Local/        AudioCapture, RecordingPlayer, TonePlayer
│  └─ Util/         NoteNameConverter
├─ Data/
│  └─ DB/           PracticeAttempt, PracticeSession
├─ Domain/
│  ├─ Pitch/        YINPitchDetector, PitchSmoother, VoiceActivityDetector, PitchScorer
│  ├─ Melody/       MelodySegmenter, MelodySession, RecordingAnalyzer, RhythmQuantizer,
│  │                KeyDetector, MelodyStep
│  ├─ Harmony/      ChordGenerator, VoiceHarmonyTrackBuilder,
│  │                SynthesizedHarmonyTrackBuilder, ToneSynthesizer,
│  │                PitchShifter(+World, +WorldAnalysis), AudioGain
│  └─ Scoring/      HarmonyPracticeScorer, PracticeSummary
└─ Features/
   ├─ Main/View/        RootTabView
   ├─ Practice/
   │  ├─ Model/         VexFlowScorePayload
   │  └─ View/          PracticeView(+Layout/+Capture/+Scoring), QuickRecordView,
   │                    VexFlowScoreView, SheetMusicFullScreenView
   └─ History/
      ├─ Model/         PracticeStatistics
      └─ View/          HistoryView, SessionDetailView
```

테스트(`HarmonyUp/Tests/`)도 같은 모양으로 미러링한다 — `Core/Util/`, `Domain/{Pitch,Melody,
Harmony,Scoring}/`, `Features/{Practice,History}/`. 기존 `PitchEngineTests/` 한 폴더에 22개가
평평하게 쌓여 있던 것이 소스와 같은 갈래로 나뉜다.

## 판단이 갈렸던 자리

**`Core/Remote`와 `Data/API`는 만들지 않는다.** junCook은 외부 API를 여럿 쓰지만 HarmonyUp은
"서버/백엔드 없음, 전 과정 온디바이스"가 원칙이라(CLAUDE.md) 네트워크 계층 자체가 없다. 빈
폴더를 규약이라는 이유로 만들어 두지 않는다.

**`NoteNameConverter`는 Domain이 아니라 `Core/Util`.** Hz↔MIDI↔음이름 변환과 `Int.mod` 확장이
들어 있고, `Core/Local`의 `AudioCapture`부터 Domain 전체, 뷰까지 모든 계층이 쓴다. Domain에 두면
Core가 Domain을 참조하게 되어 의존 방향이 뒤집힌다 — 맨 아래 계층에 두어야 모든 화살표가
아래로만 향한다.

**오디오 재생/녹음 클래스는 `Core/Local`.** `AudioCapture`/`RecordingPlayer`/`TonePlayer`는
계산이 아니라 상태를 가진 기기 I/O 래퍼다(프로젝트 문서의 표현으로는 "I/O 인접 컴포넌트").
junCook의 `Core/Local/LocationProvider`와 같은 자리다.

**신호처리 엔진은 `Domain/`을 4갈래로.** 기존 `PitchEngine/` 한 폴더에 20여 개가 평평하게
있었는데, 파일 이름만으로는 "채보 단계인지 화음 생성 단계인지"가 안 보였다. 파이프라인 순서
(음높이 검출 → 채보 → 화음 → 채점)를 폴더로 드러낸다.

**`PracticeStatistics`는 Domain이 아니라 `Features/History/Model`.** 기록 탭이 보여줄 통계
(스트릭, 자주 틀리는 음, 음정 편향) 전용이라 다른 기능이 쓰지 않는다. junCook이 기능 전용
계산기를 `Features/*/Model`에 두는 것과 같은 기준이다. `VexFlowScorePayload`도 같은 이유로
`Features/Practice/Model`이다.

## 아직 안 한 것 — ViewModel 추출

지금 `PracticeView`는 `@State` 20여 개를 직접 들고 있고, 그래서 파일이 넷으로 쪼개져 있다
(`PracticeView` + `+Layout` + `+Capture` + `+Scoring`, 합쳐 1,600줄 남짓). 진짜 MVVM으로 가려면
이 상태와 녹음/분석 흐름이 `@Observable` ViewModel로 옮겨가야 하고, 그게 이 구조 개편의 다음
단계다. 폴더 이동과 한 커밋에 섞지 않는 이유는 CLAUDE.md의 "한 커밋에 여러 개념을 동시에 바꾸지
말 것" — 파일 이동은 내용이 그대로라 리뷰가 쉽지만, 상태 재배치는 동작이 바뀔 수 있어 성격이
전혀 다르다.

참고로 junCook도 `Features/Search`와 `Features/Dashboard`에는 ViewModel 폴더가 없고
`Features/Main/ViewModel/ContentViewModel`을 공유한다 — 기능마다 ViewModel이 하나씩 있어야
하는 규약은 아니다.

## 실행 방법

```bash
scripts/apply-mvvm-structure.sh          # 드라이런 — 무엇이 어디로 갈지만 출력
scripts/apply-mvvm-structure.sh --apply  # 실제 이동 + project.yml 경로 갱신
xcodegen generate
xcodebuild -project HarmonyUp.xcodeproj -scheme HarmonyUp \
  -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3)' test
```

`--apply`는 추적 중인 파일은 `git mv`로(이름 변경 이력이 남는다), 아직 커밋 안 된 파일은 일반
`mv`로 옮긴다. 여러 번 돌려도 안전하고, 목록에 없는 새 파일이 옛 폴더에 남아 있으면 마지막에
경고로 알려준다.

**반드시 다른 세션이 파일을 고치고 있지 않을 때 돌릴 것.** 편집 중인 파일의 경로를 바꾸면 그쪽
편집이 엉뚱한 자리에 떨어지거나 옛 경로에 파일이 되살아난다 — 이 프로젝트에서 이미 겪은
동시 작업 오염 패턴이다.
