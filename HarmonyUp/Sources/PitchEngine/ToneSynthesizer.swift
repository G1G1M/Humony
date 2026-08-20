import Foundation

/// 지정한 주파수의 톤을 오프라인으로(실시간 재생이 아니라 배열로) 합성한다.
///
/// 원래(112절)는 `TonePlayer`(c757f3a, "화음 처음 넣었을 때")가 쓰던 파형(기본음 + 2배음×0.3
/// + 3배음×0.15)을 그대로 옮겼었는데, 베이스/3도/5도 세 톤이 각자 배음을 갖고 동시에 울리니
/// 배음끼리 서로 부딪혀 "너무 많은 게 들어가서 불협화음처럼 들린다"는 피드백을 받았다(113절)
/// — 배음을 다 빼고 **순수 사인파**로 단순화한다. 톤 하나만 놓고 들으면 "삐" 소리에 가깝지만,
/// 이 앱의 화음은 항상 3~4개 톤이 한꺼번에 울리므로 톤 하나하나는 단순할수록 서로 안 부딪힌다.
enum ToneSynthesizer {

    /// - Parameters:
    ///   - frequency: 합성할 톤의 주파수(Hz).
    ///   - sampleCount: 만들 샘플 개수.
    ///   - sampleRate: 샘플레이트.
    /// - Returns: `sampleCount` 길이의 순수 사인파. `frequency`가 0 이하이거나 `sampleCount`가
    ///   0 이하면 빈 배열(또는 무음)을 반환한다.
    static func synthesize(frequency: Double, sampleCount: Int, sampleRate: Double) -> [Float] {
        guard sampleCount > 0 else { return [] }
        guard frequency > 0 else { return [Float](repeating: 0, count: sampleCount) }

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
