import Foundation

/// 녹음된 오디오의 재생 속도(길이)는 그대로 유지하면서 피치만 바꾼다.
/// "내 목소리로 화음 만들기" 기능의 핵심 — 사용자가 부른 음을 녹음해서 베이스/3도/5도로
/// 피치를 옮기면, 합성음이 아니라 자기 목소리 톤으로 화음을 들을 수 있다.
///
/// **v3(48절)**: 직접 구현한 PSOLA(v2, 47절, `PitchShifterPSOLA`)를 WORLD(BSD 라이선스,
/// 음성 분석/합성계에서 널리 검증된 오픈소스 라이브러리)로 교체했다. 직접 구현이 합성
/// 신호(순음/배음 신호)와 YIN 재검출로는 "숫자상 맞는" 결과를 냈지만, 실제 목소리로는
/// 여전히 부자연스럽게 들린다는 피드백을 받았다 — 소규모 팀이 몇 시간 안에 재현하기엔
/// 음성 분석/합성이 원래 그 자체로 하나의 연구 분야다. WORLD는 F0(기본주파수)와 스펙트럼
/// 포락선(포먼트)/비주기성(숨소리 성분)을 애초에 분리해서 분석하므로, F0만 옮기고 나머지는
/// 그대로 재합성하면 포먼트가 확실히 보존된다. 실제 호출부는
/// `HarmonyUp/ThirdParty/World/HarmonyUpWorldBridge.cpp`(Swift가 못 부르는 WORLD의
/// C++ API를 C 링키지 함수 하나로 감싼 얇은 브리지) 참고.
///
/// 이 타입은 2026-08-20에 `PitchShifter`(공개 이름)에서 `PitchShifterWorld`로 이름만
/// 바뀌었다 — `PitchShifterWSOLA`/`PitchShifterPSOLA`와 나란히 두고 `PitchShifter`가
/// 셋 중 하나로 전환하는 스위처가 됐다(`PitchShifter.swift` 참고).
///
/// **124절, 화음 재설계 2단계에서 다시 복원**: git 히스토리(`96987e2^`)에서 그대로 가져옴.
/// 이번엔 "단계별로 검증하면서 적용"하기로 해서, 지금 단계는 이 래퍼+유닛테스트(합성
/// 신호로 피치 정확도 확인)까지만 — `VoiceHarmonyTrackBuilder`에 연결하는 건 다음 단계.
enum PitchShifterWorld {

    /// - Parameters:
    ///   - samples: 원본 오디오(모노, [-1, 1] 범위)
    ///   - pitchRatio: 목표 주파수 / 원래 주파수. 1보다 크면 높은 음(예: 장3도 위 = 2^(4/12)).
    ///   - formantRatio: 포먼트(스펙트럼 포락선, 음색) 이동 비율. 기본값 1.0은 "포먼트 그대로,
    ///     피치만 이동"(예전 동작과 동일). 1보다 크면 포먼트가 위로(더 맑은 음색), 작으면
    ///     아래로(더 굵은 음색) 옮겨져서 실제로 다른 성역의 목소리처럼 들린다 —
    ///     `ChordGenerator.Interval.formantRatio` 참고(docs/CONCEPTS.md 77절).
    ///   - expectedFrequency: WORLD가 직접 F0를 추정하므로 이 버전에서는 쓰지 않는다 —
    ///     기존 호출부(PracticeView)를 그대로 두기 위해 파라미터 자리만 남겨뒀다.
    /// - Returns: 길이는 원본과 같고, 피치/포먼트가 각 비율만큼 옮겨진 오디오.
    static func shift(samples: [Float], pitchRatio: Double, formantRatio: Double = 1.0, sampleRate: Double, expectedFrequency: Double? = nil) -> [Float] {
        guard !samples.isEmpty, pitchRatio > 0 else { return samples }

        // WORLD는 double 배열을 쓴다 — Float([-1,1] 범위) <-> Double 변환만 여기서 감싼다.
        let input = samples.map(Double.init)
        var output = [Double](repeating: 0, count: input.count)

        input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                HarmonyUpWorldPitchShift(
                    inputBuffer.baseAddress,
                    Int32(input.count),
                    Int32(sampleRate),
                    pitchRatio,
                    formantRatio,
                    outputBuffer.baseAddress
                )
            }
        }

        return output.map { Float($0) }
    }
}
