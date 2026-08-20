import Foundation

/// 지정한 주파수의 톤을 오프라인으로(실시간 재생이 아니라 배열로) 합성한다.
///
/// `TonePlayer`(c757f3a, "화음 처음 넣었을 때")가 `AVAudioSourceNode` 콜백 안에서 매 샘플
/// 실시간으로 만들던 것과 **정확히 같은 파형**(기본음 + 2배음×0.3 + 3배음×0.15, 배음을 더해
/// 커진 진폭을 /1.45로 재정규화)을 그대로 오프라인 버전으로 옮긴 것 — "그때 들리던 소리"를
/// 재현하는 게 목적이라 파형 자체는 새로 설계하지 않았다.
enum ToneSynthesizer {

    /// - Parameters:
    ///   - frequency: 합성할 톤의 주파수(Hz).
    ///   - sampleCount: 만들 샘플 개수.
    ///   - sampleRate: 샘플레이트.
    /// - Returns: `sampleCount` 길이의 합성 파형. `frequency`가 0 이하이거나 `sampleCount`가
    ///   0 이하면 빈 배열(또는 무음)을 반환한다.
    static func synthesize(frequency: Double, sampleCount: Int, sampleRate: Double) -> [Float] {
        guard sampleCount > 0 else { return [] }
        guard frequency > 0 else { return [Float](repeating: 0, count: sampleCount) }

        let phaseIncrement = 2.0 * Double.pi * frequency / sampleRate
        var phase = 0.0
        var output = [Float](repeating: 0, count: sampleCount)

        for i in 0..<sampleCount {
            let fundamental = sin(phase)
            let secondHarmonic = sin(phase * 2) * 0.3
            let thirdHarmonic = sin(phase * 3) * 0.15
            output[i] = Float(fundamental + secondHarmonic + thirdHarmonic) / 1.45

            phase += phaseIncrement
            if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
        }

        return output
    }
}
