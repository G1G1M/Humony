import Foundation

/// 화음(베이스/3도/5도) 목소리를 옮기는 데 지금 어떤 피치시프트 알고리즘을 쓸지 — 이 값만
/// 바꾸고 다시 빌드하면 즉시 전환된다.
///
/// 이 앱은 같은 이유("화음이 이상하게/기계음처럼 들린다")로 알고리즘을 이미 두 번
/// 교체했었다(WSOLA → PSOLA → WORLD, 각각 그 시점엔 "이상하다"는 피드백으로 다음
/// 알고리즘에 자리를 내줬다 — `PitchShifterWSOLA`/`PitchShifterPSOLA`/`PitchShifterWorld`
/// 파일 상단 문서 참고). WORLD로도 같은 종류의 제보가 계속돼서, 세 알고리즘 중 어느 게
/// 지금 이 화음 파이프라인(짧은 세그먼트 단위 피치시프트, 여러 성부 동시 재생)에 제일 잘
/// 맞는지 실기기로 직접 A/B 비교해보기로 했다(2026-08-20).
enum PitchShiftAlgorithm {
    case wsola
    case psola
    case world
}

/// 여기 값만 바꾸면 다음 빌드부터 `PitchShifter.shift(...)`가 다른 알고리즘을 쓴다.
let activePitchShiftAlgorithm: PitchShiftAlgorithm = .wsola

/// `HarmonyTrackBuilder`가 부르는 단일 진입점 — 실제 구현은 `activePitchShiftAlgorithm`에
/// 따라 `PitchShifterWSOLA`/`PitchShifterPSOLA`/`PitchShifterWorld` 중 하나로 위임한다.
/// `formantRatio`는 WORLD 전용 개념이라(WSOLA/PSOLA는 애초에 그 파라미터가 없음) 그
/// 두 경우엔 그냥 무시된다.
enum PitchShifter {
    static func shift(samples: [Float], pitchRatio: Double, formantRatio: Double = 1.0, sampleRate: Double, expectedFrequency: Double? = nil) -> [Float] {
        switch activePitchShiftAlgorithm {
        case .wsola:
            return PitchShifterWSOLA.shift(samples: samples, pitchRatio: pitchRatio, sampleRate: sampleRate, expectedFrequency: expectedFrequency)
        case .psola:
            return PitchShifterPSOLA.shift(samples: samples, pitchRatio: pitchRatio, sampleRate: sampleRate, expectedFrequency: expectedFrequency)
        case .world:
            return PitchShifterWorld.shift(samples: samples, pitchRatio: pitchRatio, formantRatio: formantRatio, sampleRate: sampleRate, expectedFrequency: expectedFrequency)
        }
    }
}
