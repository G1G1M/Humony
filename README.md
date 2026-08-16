# HarmonyUp (하모니업)

멜로디를 노래하면 화음을 자동으로 찾아주고, 그 화음을 따라 부르며 실시간으로 채점받는 iOS 화음 훈련 앱.

전체 배경(문제의식, 경쟁 분석, 페르소나 등)은 [`docs/prd.md`](docs/prd.md), 개발 지침은 [`CLAUDE.md`](CLAUDE.md) 참고. 신호처리 개념 학습 노트는 [`docs/CONCEPTS.md`](docs/CONCEPTS.md)에 계속 정리 중.

## 기술 스택

- Swift, SwiftUI
- AVAudioEngine / AVAudioSession — 마이크 캡처
- YIN 알고리즘 직접 구현 (Accelerate/vDSP) — 서드파티 피치 검출 라이브러리 미사용
- 서버 없음 — 전 과정 온디바이스
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `project.yml`로 `.xcodeproj` 생성 (커밋 대상 아님, `xcodegen generate`로 재생성)

## 진행 상황

- [x] **Phase 1 — YIN 피치 검출 프로토타입**: 실기기 검증 완료(±10 cent 이내, 저음~고음 옥타브 오차 없음). 상세: [`docs/phase-1-yin-prototype.md`](docs/phase-1-yin-prototype.md)
- [x] **Phase 2 — 조성 판별 + 화음 생성 (핵심 로직)**: `KeyDetector`, `ChordGenerator` 구현+테스트 완료
- [x] **Phase 2 — 마이크 파이프라인과 연결**: `MelodySession`으로 프레임별 감지 결과를 누적해 조성 판별+화음 제안까지 실기기에서 실시간 동작 확인
- [x] **Phase 3 — 화음 발성 훈련 UI + 실시간 채점**: `TonePlayer`(목표음/시작음 재생), `PitchScorer`(cent 채점), `PitchMeterView`(튜너 스타일 바늘 미터), `PitchSmoother`(비브라토 완화), 단음 캡처 모드(같은 음 3프레임 유지돼야 확정, 확정 후 고정), 3도/5도 각각 채점 가능. 콜앤리스폰스 방식으로 마이크/스피커 피드백 루프 회피. 실기기 확인 완료
- [ ] Phase 3 — 세션 종료 후 정확도 요약 + 자주 벗어난 화음 유형 리포트

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

## 개발

```bash
xcodegen generate   # project.yml -> HarmonyUp.xcodeproj
xcodebuild -project HarmonyUp.xcodeproj -scheme HarmonyUp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test
```
