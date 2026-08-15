# Phase 1 — YIN 피치 검출 프로토타입

## 목표

마이크 입력에서 실시간으로 기본 주파수(F0)를 검출해 콘솔에 출력하는 프로토타입을 만든다. UI, 화음 생성, 채점 로직은 포함하지 않는다.

## 완료 조건 (Acceptance Criteria)

- [x] AVAudioEngine으로 마이크 입력을 실시간 캡처한다
- [x] Accelerate(vDSP) 기반 자기상관 함수로 YIN 알고리즘을 구현한다
- [x] 감지된 주파수(Hz)와 가장 가까운 노트명(예: A4, 440Hz)을 실시간으로 콘솔에 출력한다
- [x] 무음/저에너지 구간은 간단한 에너지 임계값 기반 VAD로 걸러내고 출력하지 않는다
- [x] 조용한 환경에서 알려진 기준음(튜너 앱, 피아노 앱 등)과 비교했을 때 오차가 ±10 cent 이내다
- [x] 체감 지연이 200ms 이내다
- [x] 피치 검출 함수는 향후 pYIN(다중 후보 + 확률)으로 확장 가능하도록, 단일 값이 아니라 후보를 반환할 수 있는 시그니처로 설계한다 (지금 당장 다중 후보 구현은 하지 않아도 됨)

**검증 기록 (2026-08-15)**: 실기기(iPhone 17)에서 스피커로 재생한 기준음과 비교해 ±10 cent 이내 정확도 확인. 저음(E3)~고음(A4) 글리산도 구간에서도 옥타브 오차 없이 매끄럽게 트래킹됨. VAD 기본 임계값(0.0001)이 실제 환경에서 별도 조정 없이 적절하게 동작함. Phase 1 완료.

## 범위 밖 (지금 하지 않음)

- UI 화면 구성
- 조성 판별, 화음 생성 로직
- 세션 기록 저장 (SwiftData)
- watchOS, iPadOS, macOS 확장
- pYIN으로의 실제 확장 (인터페이스만 열어둘 것)

## 제안 프로젝트 구조

```
HarmonyUp/
  Sources/
    PitchEngine/
      YINPitchDetector.swift      # YIN 알고리즘 핵심 로직 (순수 함수)
      AudioCapture.swift          # AVAudioEngine 마이크 캡처 래퍼
      VoiceActivityDetector.swift # 간단한 에너지 기반 VAD
      NoteNameConverter.swift     # Hz -> 노트명 변환
    HarmonyUpApp.swift             # 최소 SwiftUI 앱 진입점 — 감지된 Hz/노트명을 화면에 텍스트로 출력
  Tests/
    PitchEngineTests/
      YINPitchDetectorTests.swift # 알려진 사인파 입력에 대한 정확도 테스트
```

최종 타깃이 iOS 앱이므로 Phase 1부터 iOS SwiftUI 앱 타깃으로 시작한다(별도 macOS 커맨드라인 타깃 사용 안 함). 마이크 권한(Info.plist `NSMicrophoneUsageDescription`), AVAudioSession 카테고리 설정을 이 단계에서 바로 처리해 나중에 이식 비용이 들지 않도록 한다. 화면은 감지된 Hz/노트명을 텍스트로 뿌리는 수준이면 충분하고, UI 디자인은 이 단계 범위가 아니다.

## 검증 방법 제안

1. 사인파 생성기로 알려진 주파수(예: 440Hz)를 입력해 `YINPitchDetector`의 정확도를 유닛 테스트로 검증한다.
2. **실기기에서** 튜너 앱과 나란히 켜놓고 육안으로 비교한다 — 시뮬레이터는 Mac 마이크를 패스스루하지만 지연/게인 특성이 실기기와 달라 지연(200ms) 및 정확도(±10 cent) 기준 검증에는 적합하지 않다.
3. 잡음이 섞인 환경에서 VAD가 오탐하지 않는지 확인한다.

## 참고 — 관련 리스크 및 대응

상세 내용은 `docs/prd.md`의 "부록 B. 기술적 리스크 및 보완 방안" 참고.

- 잡음 환경에서 정확도 저하 → VAD로 1차 완화, 추후 pYIN 확장으로 2차 완화
- 옥타브 오차 → pYIN 확장 시 크게 개선됨 (v1 프로토타입 단계에서는 알려진 한계로 남겨둠)
