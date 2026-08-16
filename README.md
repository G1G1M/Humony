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

- [x] **Phase 1 — YIN 피치 검출 프로토타입**: 실기기 검증 완료(±10 cent 이내, 저음~고음 옥타브 오차 없음). 상세: [`docs/phase-1-yin-prototype.md`](docs/phase-1-yin-prototype.md)
- [x] **Phase 2 — 조성 판별 + 화음 생성 (핵심 로직)**: `KeyDetector`, `ChordGenerator` 구현+테스트 완료
- [x] **Phase 2 — 마이크 파이프라인과 연결**: `MelodySession`으로 프레임별 감지 결과를 누적해 조성 판별+화음 제안까지 실기기에서 실시간 동작 확인
- [x] **Phase 3 — 화음 발성 훈련 UI + 실시간 채점**: `TonePlayer`(목표음/시작음 재생), `PitchScorer`(cent 채점), `PitchMeterView`(튜너 스타일 바늘 미터), `PitchSmoother`(비브라토 완화), 단음 캡처 모드(같은 음 3프레임 유지돼야 확정, 확정 후 고정), 3도/5도 각각 채점 가능. 콜앤리스폰스 방식으로 마이크/스피커 피드백 루프 회피. 실기기 확인 완료
- [x] **Phase 3 — 세션 종료 후 정확도 요약 + 자주 벗어난 화음 유형 리포트**: `PracticeSummary`(채점 시도를 요약 통계로 압축) + `PracticeAttempt`(SwiftData 저장) + 3도/5도 평균 정확도 비교. Phase 3 완료
- [x] **멜로디 모드**: 단음 모드(한 음 잡고 고정)와 별개로, 음을 계속 이어 부르면 음마다 화음이 순서대로 쌓이는 모드 추가 — `MelodySession`의 원래 설계(곡 전체 처리)를 실제로 사용하는 화면
- [x] **멜로디 스텝 수동 수정**: 실시간 검출이 틀렸을 때(예: F#3으로 오검출) 눌러서 직접 고칠 수 있음. 수정 시 조성 재판별 + 전체 스텝 화음 재계산
- [x] **측정 시작/중지 버튼**: onAppear 자동 시작 대신 사용자가 원하는 시점에 마이크 캡처 시작
- [x] **멜로디 전체 화음 라인**: "전체 3도/5도 듣기" — 멜로디 전체에 대응하는 화음을 이어서 재생, 끝나면 자동 정지
- [x] **내 목소리로 화음 만들기**: 합성음 대신 목소리를 짧게 녹음해 `PitchShifter`(WSOLA)로 피치를 옮겨 재생. 실기기 청취 확인 완료("일단 되긴해 내 목소리로")
- [x] **내 목소리로 전체 화음 + 음량 증폭**: 원음+3도+5도를 한 번에 믹싱해서 재생하는 "전체 화음" 버튼 추가, `AudioGain`으로 재생 전 샘플 자체를 스케일업(피크 정규화)해 체감 음량 확보
- [x] **음정 흔들림 수정**: "음이 왔다갔다한다" 피드백 → 롤링 버퍼에 섞인 이전 음/잡음을 잘라내는 `VoiceSegmentTrimmer` 추가(최근의 안정된 한 음 구간만 남겨서 피치 시프트)
- [x] **멜로디 모드 화음이 뒷부분만 들리던 문제 수정**: 단음 모드 전용으로 설계된 트리밍/1.5초 버퍼 상한을 멜로디 모드에도 그대로 적용한 게 원인 → 멜로디 모드는 버퍼 상한 30초로 확장 + 트리밍 생략(부른 멜로디 전체를 그대로 옮김)
- [x] **음이 끊기고 일부가 통째로 빠지던 근본 원인 수정**: 롤링 버퍼가 피치 검출 성공한 프레임만 담고 있어서, 음 사이 숨소리 구간이 잘려 이어붙듯 들리고 짧거나 조용한 음은 통째로 누락됐음(6음 중 5음만 들림). `AudioCapture` 콜백에 raw 샘플을 항상 함께 넘기도록 바꿔서, 검출 성공 여부와 무관하게 실제 마이크 파형이 원래 타이밍 그대로 버퍼에 쌓이게 수정
- [x] **화음 만드는 속도 개선**: Debug 빌드가 기본적으로 최적화 없이(`-Onone`) 컴파일되던 게 WSOLA 연산을 느리게 만든 주 원인 → Debug 설정에서도 `SWIFT_OPTIMIZATION_LEVEL: -O`로 컴파일하도록 변경 + `PitchShifter`의 가장 무거운 내적 계산을 Accelerate(`vDSP_dotpr`)로 벡터화
- [x] **목소리 화음 재생 중 마이크 미차단 버그 수정**: `VoiceClipPlayer` 재생만 콜앤리스폰스 규칙(`isPlaybackBusy`)에서 빠져 있어서, 재생 중 스피커 소리가 마이크로 되먹임돼 멜로디/조성 판단이 오염되던 근본 원인 발견·수정. 재생 완료 시점을 정확히 추적(`completionCallbackType: .dataPlayedBack`)해서 `isPlayingVoiceClip` 상태로 반영
- [x] **출력 음질 다듬기**: WSOLA 오버랩을 75%→87.5%로 올려 그레인 경계의 지지직거림 완화(vDSP 최적화로 확보한 여유를 재투자, 연산량 거의 그대로), 재생 시작/끝 클릭음 제거용 페이드 인/아웃(`AudioGain.applyFadeInOut`) 추가
- [x] **UI/UX 리디자인 — 탭 구조 + 카드 분리**: 앱을 "연습"/"기록" 탭 2개로 나누고(`RootTabView`), `ContentView.swift`(955줄, 단일 화면)를 `PracticeView.swift`(연습 탭)+`HistoryView.swift`(기록 탭)+`MelodyStepRow.swift`로 분리. 화면은 번호 섹션 대신 `HarmonyCard` 카드로 재구성하고, 데이터가 없는 카드는 아예 렌더링하지 않는 점진적 공개 적용(첫 음 잡히기 전엔 캡처 카드만 보임). 시뮬레이터에서 라이트/다크 + 실제 탭 전환까지 스크린샷으로 확인, 실기기 설치·실행 완료
- [x] **폰트를 Pretendard로 통일**: 오픈소스 폰트(SIL OFL) 4개 굵기(Regular/Medium/SemiBold/Bold)를 앱에 번들. `Theme.Typography`가 `Font.custom(_:size:relativeTo:)`로 Dynamic Type을 유지하면서 커스텀 폰트를 적용. 실시간 숫자 표시(Hz/cent 등)는 자릿수 흔들림 방지 목적이 있어 시스템 모노스페이스 예외 유지. 실기기 설치·실행 완료
- [x] **마이크 권한 거부 상태 전용 UI**: `AVAudioApplication.recordPermission` 확인 → 거부 시 전용 카드(아이콘+설명+"설정 열기" 버튼)로 안내, 미결정 시 시스템 권한 팝업 요청. 시뮬레이터에서 `simctl privacy revoke`로 거부 상태를 강제 재현해 실제 화면 확인
- [x] **Dynamic Type 최대 크기 검증 + 레이아웃 수정**: 시뮬레이터를 접근성 최대 글자 크기로 강제 설정해 실제로 확인 → 버튼 여러 개가 나란한 곳(시작음 컨트롤, 전체 3도/5도 듣기, 내 목소리로 3도/5도/전체 화음)에서 텍스트가 찌그러지고 겹치는 문제 발견·수정. `ViewThatFits`로 "가로에 안 들어가면 세로로" 자동 전환
- [x] **녹음 파형 시각화**: `WaveformView` 추가 — 측정 중일 때 실시간 피치 카드에 마이크 입력을 세로 막대 파형으로 표시(구간별 피크 다운샘플링 + 화면 내 최댓값 기준 정규화). 캡처 카드/목소리 화음 카드의 정보 그룹 간격 정리(설명을 버튼 위로 이동 등). 레퍼런스 이미지(음성 녹음 앱들) 참고, 기존 보라색 계열 틴트 유지
- [x] **버튼 아이콘 다듬기**: 측정 시작/중지, 화음 듣기/정지, 채점/중지, 다시 시작 등 상태를 표현하는 버튼에 SF Symbol 아이콘 추가(상태 전환 시 아이콘도 함께 바뀜 — 예: `mic.fill`↔`stop.fill`). 짧은 라벨 버튼(3도/5도 등)은 의미 있는 아이콘이 없어 제외. UI/UX 리디자인 1차 마무리
- [x] **카드 등장 애니메이션 + 자동 스크롤**: 화면을 단계별로 나누는 대신, 카드가 조건부로 나타날 때 `.transition`(페이드+위에서 이동)으로 애니메이션 처리하고 `ScrollViewReader`로 새로 나타난 카드까지 자동 스크롤

## 구성 요소 (`HarmonyUp/Sources/PitchEngine/`)

| 파일 | 역할 |
|---|---|
| `NoteNameConverter` | Hz ↔ MIDI 노트/음이름/cent 변환 |
| `YINPitchDetector` | 자기상관 기반 YIN 기본 주파수(F0) 검출 |
| `VoiceActivityDetector` | 에너지 임계값 기반 무음 구간 필터링 |
| `AudioCapture` | AVAudioEngine 마이크 캡처 + 파이프라인 연결 |
| `KeyDetector` | pitch-class 히스토그램 기반 조성 판별 (Temperley 1999 key profile) |
| `ChordGenerator` | 판별된 조성 기준 diatonic 3도/5도 화음 생성 |
| `MelodySession` | 프레임별 감지 결과를 누적해 KeyDetector/ChordGenerator에 연결 |
| `TonePlayer` | 지정 주파수 톤 재생(배음+envelope) — 제안된 화음/시작음을 귀로 확인 |
| `PitchScorer` | 목표 주파수 대비 사용자 음정의 cent 편차 채점 |
| `PitchSmoother` | MIDI 노트(로그 스케일) 기준 EMA로 비브라토·흔들림 완화 |
| `PracticeSummary` | 채점 시도(Score 배열)를 정확도/평균편차 요약 통계로 압축 |
| `PracticeAttempt` | SwiftData 모델 — 채점 시도 요약을 세션 기록으로 저장 |
| `PitchShifter` | WSOLA 기반 피치 시프팅 — 길이는 유지하고 피치만 이동 |
| `VoiceClipPlayer` | 임의의 오디오 버퍼([Float])를 한 번 재생 |
| `AudioGain` | 재생 전 샘플 자체를 스케일업하는 피크 정규화 + 여러 트랙 믹싱 |
| `VoiceSegmentTrimmer` | 롤링 버퍼에서 목표음과 가까운 최근의 안정된 구간만 잘라내기 |

## 개발

```bash
xcodegen generate   # project.yml -> HarmonyUp.xcodeproj
xcodebuild -project HarmonyUp.xcodeproj -scheme HarmonyUp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test
```
