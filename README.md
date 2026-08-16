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
- [x] **"빠른 녹음 → 악보 → 연습" 로드맵 Phase 1 — `MelodySegmenter`**: 녹음 전체를 배치로 분석해 음표(음높이+시작시간+길이)로 잘라내는 신규 컴포넌트(윈도우 분석→디바운스→런랭스 인코딩). 유닛테스트 7개
- [x] **로드맵 Phase 2 — `RecordingAnalyzer`**: `MelodySegmenter` 출력을 기존 `KeyDetector`/`ChordGenerator`에 연결하고, 그 결과를 기존 `MelodyStep` 배열로 변환. 유닛테스트 3개
- [x] **로드맵 Phase 3 — "빠른 녹음" 모드 UI(`QuickRecordView`)**: 대기→녹음 중→분석 중→결과 상태머신 + 녹음 전체 파형 표시(최대 30초). "녹음 그만"을 누르면 `RecordingAnalyzer`로 배치 분석하고, 그 결과를 `correctMelodyStep`과 같은 합성 `DetectionResult` 패턴으로 `melodySession`에 되먹여서 — 기존 조성+화음 카드/`MelodyStepRow` 목록/"내 목소리로 화음"/따라 부르기 채점을 전혀 손대지 않고 그대로 재사용. `SessionMode`에 `.quickRecord` 추가(기본 모드로 설정, 단음/멜로디는 유지). 실기기(Ian) 설치+실행 확인 완료
- [x] **빠른 녹음 화면 비주얼 리디자인**: 음성 녹음 앱 레퍼런스를 참고해, 대기/녹음 중 상태를 `HarmonyCard` 없이 화면 주인공이 되는 히어로 레이아웃으로 재구성 — 큰 원형 마이크 버튼(`Theme.tint` 채움+헤일로 링)+큰 소개 문구(`Theme.Typography.largeTitleBold` 신규 토큰)+안내 캡션만 남기고, 녹음 중엔 파형 카드+경과시간+정지/취소 버튼. 분석 중/결과/에러 상태는 `QuickRecordView`가 스스로 카드형 컨테이너를 그려서 붕 뜨지 않게 함. 화면 하단 전역 "다시 시작" 버튼은 빠른 녹음 모드에서 상태별 버튼과 중복돼 숨김. 시뮬레이터 라이트/다크 모드 스크린샷 확인, 유닛테스트 79개 통과
- [x] **단음/멜로디 모드 완전 제거 — 연습을 빠른 녹음 하나로 통합**: 모드 피커 삭제, `SessionMode`/실시간 프레임 확정 로직(`pendingPitchClass`/`pendingStreak`/`captureStreakRequired` 등)/`toggleCapture()`/`VoiceSegmentTrimmer`(+테스트)까지 전부 제거 — 멜로디 기능은 빠른 녹음이 이미 포함하고 있어 기능 손실 없음. 겸사겸사 "녹음 후 내 목소리로 화음 버튼이 안 눌리던" 버그 수정 — `.disabled` 조건이 실시간 캡처 시절 값(`isCapturing`, 녹음 끝나면 곧장 false가 됨)을 그대로 쓰고 있던 게 원인이라 `recentVoiceBuffer.isEmpty` 기준으로 교체. 유닛테스트 74개 통과
- [x] **아카펠라 4성부 화음 엔진(리드+베이스+이너보이스1(3도)+이너보이스2(5도))**: `ChordGenerator`가 멜로디 음 자신을 근음으로 삼아 베이스(1옥타브 아래)+3도/5도(베이스와 멜로디 사이)를 반환하도록 보이싱 전면 재작성 — 외부 "반주 코드" 입력 없이 멜로디만으로 전 성부 자동 생성(반주 오디오/코드 데이터 소스가 없는 이 앱 구조상 확정한 방향). 성부 교차 방지를 수학적으로 보장(3도 거리<5도 거리<베이스-멜로디 거리). `MelodyStep`을 성부별 딕셔너리(`harmonyVoices`)로 전환하고 멜로디 스텝 목록/재생(합성음+내 목소리 4트랙 믹싱)/채점(3패널)/기록 집계까지 전체 파이프라인에 베이스 연결. 유닛테스트 74개 통과, 실기기(Ian) 설치+실행 완료
- [x] **음질/음량 개선 — RMS 러프니스 정규화 + 다운샘플링 안티에일리어싱**: `AudioGain.normalizeLoudness`(피크 대신 RMS 기준 게인, 클리핑 방지 peakCeiling 병행) 추가, `mixAndNormalize`가 합치기 전에 트랙별로 먼저 러프니스를 맞춰 성부 간 음량 불균등 해소. `PitchShifter.resample`의 다운샘플링(음을 높일 때) 직전에 안티에일리어싱 저역통과 필터 추가
- [x] **`PitchShifter`를 리샘플링 없는 피치 동기(PSOLA) 방식으로 전면 재작성 — 포먼트 보존**: "화음이 기계음 같다"는 피드백의 근본 원인이 리샘플링 기반 피치시프트가 포먼트(성도 공명 특성)를 피치와 함께 왜곡시키는 것이었음을 확인 — 리샘플링 단계를 없애고, 읽는 위치/쓰는 위치를 다른 속도로 전진시켜 그레인을 원본 그대로 재배치하는 방식으로 재작성(그레인 파형 자체는 리샘플링하지 않아 포먼트 유지). 순음 대신 배음이 풍부한 합성 신호로 테스트를 다시 만들어 베이스(옥타브 아래)까지 정확한 피치 시프트를 검증. "화음만 듣기(멜로디 제외)" 버튼 추가. 유닛테스트 83개 통과, 실기기(Ian) 설치+실행 완료
- [x] **직접 구현한 PSOLA를 WORLD 보코더로 교체(현재 사용 중)**: 위 PSOLA로도 "전체 화음이 더 이상하게 들린다"는 실기기 청취 피드백을 받아, [WORLD](https://github.com/mmorise/World)(BSD 라이선스, 검증된 음성 분석/합성 라이브러리)를 도입 — F0(기본주파수)/스펙트럼 포락선(포먼트)/비주기성을 분리해서 분석하고, F0만 원하는 비율로 스케일한 뒤 나머지는 그대로 재합성. WORLD 공개 API가 C 링키지라 얇은 C 브리지(`HarmonyUp/ThirdParty/World/HarmonyUpWorldBridge.h/.cpp`)만으로 Swift에서 직접 호출(`PitchShifter`의 공개 API는 그대로라 호출부 무변경). F0 추정을 Harvest에서 Dio+StoneMask로 바꿔 처리 속도 개선(30초 클립 기준 5.1초→3.6초). 유닛테스트 78개 통과(성능 회귀 테스트 포함), arm64 실기기 컴파일 확인 — 실기기 청취 결과 "생각보다 퀄 좋다"는 긍정 확인 받음
- [x] **화음에 질감 더하기 — 리버브 + 보컬 더블링**: `VoiceClipPlayer`에 공유 `AVAudioUnitReverb`(`.mediumRoom`, wetDryMix 18%) 추가 — 성부들이 같은 공간에서 함께 부르는 듯한 일체감. `VoiceDoubler`(신규) — 베이스/3도/5도 각각을 살짝 지연(15~40ms)+미세 디튠(몇 센트)한 복사본과 섞는 ADT(더블링) 기법으로 "한 목소리를 피치만 옮긴 것"이 아니라 "다른 사람이 한 번 더 부른" 듯한 두께 추가, 성부마다 지연/디튠 값을 다르게 줘서 인공적인 동기화 방지, 멜로디(원음)는 더블링 제외. 리버브 도입 과정에서 재생 그래프 포맷 관련 버그 2건(리버브 노드 기본 포맷 불일치, "다시 녹음" 후 샘플레이트 변경 미반영) 발견·수정. 유닛테스트 85개 통과, 실기기(Ian) 설치+실행 완료 — 청취 확인 대기 중
- [x] **베이스 리듬 독립화 — 화음이 "뻣뻣하다"는 피드백 대응**: 화성학(SATB voice leading, 병행/반진행)·아카펠라 편곡 리서치로 원인 진단(멜로디 음을 그대로 근음 삼는 구조 → 병행 진행 + 화성 리듬이 멜로디 리듬과 동일 + 베이스가 멜로디 리듬을 그대로 복사). 그중 지금 구조를 거의 안 건드리고 적용 가능한 "베이스 리듬 독립화"부터 착수 — `NoteSequenceGrouper`(신규, 순수 함수) 추가해 "전체 베이스/3도/5도 듣기" 재생이 연속된 같은 음을 매번 재트리거하지 않고 하나의 지속음으로 묶도록 수정(총 재생 길이는 그대로 유지). 유닛테스트 92개 통과, 실기기(Ian) 설치+실행 완료
- [ ] **로드맵 Phase 4~9**: 다중 트랙 동시 재생(성부별 뮤트), 악보 렌더링(`StaffGeometry`/`SheetMusicView`), 성부 표시/재생 공유 토글, 카라오케 재생헤드 동기화, 연습 탭 최종 통합, 다듬기

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
| `PitchShifter` | 피치 시프팅(길이 유지, 피치만 이동) — [WORLD](https://github.com/mmorise/World)(BSD, `HarmonyUp/ThirdParty/World/`) 호출로 포먼트 보존 |
| `VoiceClipPlayer` | 임의의 오디오 버퍼([Float])를 한 번 재생, 공유 `AVAudioUnitReverb`로 공간감 부여 |
| `AudioGain` | 재생 전 샘플 자체를 스케일업하는 피크 정규화 + 여러 트랙 믹싱 |
| `VoiceDoubler` | 성부별 지연+미세 디튠 복사본을 섞는 보컬 더블링(ADT) |
| `MelodySegmenter` | 녹음 전체를 배치로 분석해 음표(음높이+시작시간+길이) 목록으로 잘라내기 |
| `RecordingAnalyzer` | `MelodySegmenter` 출력을 `KeyDetector`/`ChordGenerator`에 연결해 기존 `MelodyStep` 배열로 변환 |
| `NoteSequenceGrouper` | 연속된 같은 음을 하나의 지속음으로 묶어 재트리거 없이 재생(베이스 리듬 독립화) |

## 개발

```bash
xcodegen generate   # project.yml -> HarmonyUp.xcodeproj
xcodebuild -project HarmonyUp.xcodeproj -scheme HarmonyUp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test
```
