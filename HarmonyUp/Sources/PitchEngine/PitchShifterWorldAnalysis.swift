import Foundation

/// WORLD 분석 결과(F0/스펙트럼 포락선/비주기성)를 한 번만 계산해서 여러 화음 성부가
/// 나눠 쓰기 위한 핸들. 129절, "화음 음마다 개별 재분석" 대신 "전체 한 번 분석 + F0곡선
/// 재합성" 구조 개선의 1단계 — C++ 쪽(`HarmonyUpWorldBridge.cpp`)의 불투명 포인터를
/// Swift에서 RAII로 감싼다(`deinit`에서 자동 해제, 수동 free 호출 불필요).
///
/// 쓰는 법: 원본 목소리 전체로 한 번 `init`한 뒤, 화음 성부(베이스/3도/5도)마다
/// `f0`(원본 곡선)를 읽어 원하는 구간만 비율을 바꾼 새 배열을 만들고, 그 배열로
/// `synthesize(f0:formantRatio:)`를 성부 수만큼 반복 호출한다 — 분석(느린 부분)은
/// 한 번만 하고 재합성만 반복하므로, 기존에 음마다/성부마다 매번 새로 분석하던 것보다
/// 빠르고, 무엇보다 목소리 전체가 하나로 이어진 채 처리되어 세그먼트 경계 이음매가
/// 원리적으로 생기지 않는다.
final class PitchShifterWorldAnalysis {
    private let handle: OpaquePointer

    /// 수정 가능한 F0 곡선의 프레임 개수 — `f0`와 `synthesize(f0:)`에 넘기는 배열의
    /// 길이가 정확히 이 값과 같아야 한다.
    let f0Length: Int

    /// 프레임 간격(ms) — 프레임 인덱스 i의 실제 시각(초)은 `i * framePeriodMs / 1000.0`.
    let framePeriodMs: Double

    /// 분석에 쓰인 원본 오디오 길이(샘플 수) — `synthesize`가 돌려주는 배열도 이 길이다.
    let inputLength: Int

    /// 원본(수정 전) F0 곡선 — 화음 곡선을 만들 때 "이 프레임의 원래 주파수"가 필요할 때 쓴다.
    let f0: [Double]

    /// - Parameter d4cThreshold: WORLD의 D4C 비주기성(숨소리/노이즈) 추정 임계값 — 기본값
    ///   0.85는 WORLD 자체 기본값(`world::kThreshold`)과 같다. 값을 낮추면 "충분히 깨끗하다"고
    ///   판단해 지름길로 순수 톤 처리하는 프레임이 줄어들어(D4C Love Train), 더 많은 프레임에서
    ///   실제 비주기성을 정교하게 계산한다 — 132절, "기계음처럼 들린다" 피드백에 대한 실험용
    ///   손잡이(`HarmonyUpWorldBridge.h` 참고).
    /// - Returns: 분석에 실패하면(빈 입력, WORLD 최소 분석 길이보다 짧은 입력 등) nil.
    init?(samples: [Float], sampleRate: Double, d4cThreshold: Double = 0.85) {
        guard !samples.isEmpty else { return nil }
        let input = samples.map(Double.init)

        guard let handle = input.withUnsafeBufferPointer({ buffer in
            HarmonyUpWorldAnalyze(buffer.baseAddress, Int32(input.count), Int32(sampleRate), d4cThreshold)
        }) else { return nil }

        self.handle = handle
        self.f0Length = Int(HarmonyUpWorldF0Length(handle))
        self.framePeriodMs = HarmonyUpWorldFramePeriodMs(handle)
        self.inputLength = Int(HarmonyUpWorldInputLength(handle))

        var f0 = [Double](repeating: 0, count: f0Length)
        f0.withUnsafeMutableBufferPointer { buffer in
            HarmonyUpWorldGetF0(handle, buffer.baseAddress)
        }
        self.f0 = f0
    }

    deinit {
        HarmonyUpWorldFreeAnalysis(handle)
    }

    /// `modifiedF0`(길이는 반드시 `f0Length`와 같아야 함)로 재합성한다 — 스펙트럼 포락선/
    /// 비주기성은 분석 시점 원본을 그대로 재사용하고 F0만 바꿔치기하므로, 분석은 다시
    /// 돌지 않는다(이 클래스의 존재 이유).
    /// - Parameter formantRatio: `PitchShifterWorld.shift`와 같은 의미 — 1.0이면 포먼트
    ///   그대로, 그 외엔 스펙트럼 포락선을 주파수 축으로 워핑.
    func synthesize(f0: [Double], formantRatio: Double = 1.0) -> [Float] {
        precondition(f0.count == f0Length, "modifiedF0 length must match f0Length")

        var output = [Double](repeating: 0, count: inputLength)
        f0.withUnsafeBufferPointer { f0Buffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                HarmonyUpWorldSynthesizeWithF0(handle, f0Buffer.baseAddress, formantRatio, outputBuffer.baseAddress)
            }
        }
        return output.map { Float($0) }
    }
}
