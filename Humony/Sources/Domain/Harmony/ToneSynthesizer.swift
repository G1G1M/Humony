import Foundation

/// 지정한 주파수의 톤을 오프라인으로(실시간 재생이 아니라 배열로) 합성한다.
///
/// **120절, 화음 재설계 1단계**: 배음 없는 순수 사인파로 시작한다. 예전(112절)엔 `TonePlayer`와
/// 같은 파형(기본음+2배음×0.3+3배음×0.15)을 썼는데, 베이스/3도/5도 세 톤이 동시에 울리면
/// 톤마다의 배음까지 서로 부딪혀 "불협화음처럼 들린다"는 문제가 있었다(113절에서 실제로 겪고
/// 배음을 뺐던 적이 있음). 지금 단계의 목표는 소리 자체의 아름다움이 아니라 "화음 선택과
/// 타이밍이 맞는지"를 깨끗하게 검증하는 것이라, 가장 단순하고 변수가 적은 순수 사인파부터
/// 시작한다 — 소리가 로봇처럼 들리는 건 이 단계에서 감수할 부분이다.
enum ToneSynthesizer {

    /// - Parameters:
    ///   - frequency: 합성할 톤의 주파수(Hz).
    ///   - sampleCount: 만들 샘플 개수.
    ///   - sampleRate: 샘플레이트.
    /// - Returns: `sampleCount` 길이의 사인파. `frequency`가 0 이하이거나 `sampleCount`가
    ///   0 이하면 무음(또는 빈 배열)을 반환한다.
    static func synthesize(frequency: Double, sampleCount: Int, sampleRate: Double) -> [Float] {
        guard sampleCount > 0 else { return [] }
        guard frequency > 0, sampleRate > 0 else { return [Float](repeating: 0, count: sampleCount) }

        let phaseIncrement = 2.0 * Double.pi * frequency / sampleRate
        var phase = 0.0
        var output = [Float](repeating: 0, count: sampleCount)

        for i in 0..<sampleCount {
            output[i] = Float(sin(phase))
            phase += phaseIncrement
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        }

        return output
    }
}
