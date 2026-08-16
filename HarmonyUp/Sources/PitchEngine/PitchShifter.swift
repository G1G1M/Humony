import Foundation

/// 녹음된 오디오의 재생 속도(길이)는 그대로 유지하면서 피치만 바꾼다.
/// "내 목소리로 화음 만들기" 기능의 핵심 — 사용자가 부른 음을 녹음해서 3도/5도 위로
/// 피치를 옮기면, 합성음이 아니라 자기 목소리 톤으로 화음을 들을 수 있다.
enum PitchShifter {

    /// - Parameters:
    ///   - samples: 원본 오디오(모노, [-1, 1] 범위)
    ///   - pitchRatio: 목표 주파수 / 원래 주파수. 1보다 크면 높은 음(예: 장3도 위 = 2^(4/12)).
    /// - Returns: 길이는 원본과 거의 같고, 피치만 pitchRatio배 된 오디오.
    static func shift(samples: [Float], pitchRatio: Double, sampleRate: Double) -> [Float] {
        guard !samples.isEmpty, pitchRatio > 0 else { return samples }

        // 1단계: 길이를 pitchRatio배로 늘이거나 줄인다(피치는 그대로 유지, WSOLA).
        // 2단계: 그 결과를 pitchRatio배 빠르기로 리샘플링한다 — 리샘플링은 피치와 길이를
        // 동시에 pitchRatio배 하기 때문에, 1단계에서 미리 늘려둔 길이가 다시 원래 길이로
        // 돌아오면서 피치만 pitchRatio배로 바뀐 결과가 나온다.
        let stretched = timeStretch(samples: samples, factor: pitchRatio)
        return resample(samples: stretched, rate: pitchRatio)
    }

    // MARK: - 1단계: WSOLA(Waveform-Similarity Overlap-Add) 시간축 늘이기/줄이기

    // 그레인(조각) 하나의 길이. 너무 작으면 음색이 뭉개지고, 너무 크면 겹치는 자연스러움이 떨어진다 —
    // 44.1kHz 기준 약 23ms로, 사람 목소리의 한 피치 주기(수 ms)보다 충분히 길다.
    private static let grainSize = 1024

    // 그레인을 75% 겹치게(hop = grainSize/4) 이어붙인다 — 겹침이 클수록 이음매가 부드러워지지만
    // 계산량이 늘어난다. 프로토타입에서 자연스러움과 성능의 절충점으로 골랐다.
    private static let hopDivisor = 4

    // internal(private 아님)로 열어둔 이유: 유닛테스트에서 1단계(시간축 변형)와 2단계(리샘플링)를
    // 각각 따로 검증해서 버그가 어느 단계에 있는지 격리하기 위함.
    static func timeStretch(samples: [Float], factor: Double) -> [Float] {
        let hop = grainSize / hopDivisor
        // factor(=pitchRatio)가 1보다 크면(음을 높이려는 경우) 입력을 더 천천히(작은 보폭으로)
        // 읽어서, 출력이 원본보다 길어지게 만든다 — 그래야 2단계 리샘플링 후 원래 길이로 돌아온다.
        let inputHop = Double(hop) / factor
        let searchRadius = hop

        let outputLength = max(grainSize, Int(Double(samples.count) * factor))
        var output = [Float](repeating: 0, count: outputLength + grainSize)
        var weight = [Float](repeating: 0, count: outputLength + grainSize)
        let window = hannWindow(size: grainSize)

        var outPos = 0.0
        var idealInPos = 0.0
        var previousActualStart: Int?

        while Int(outPos) < outputLength {
            let idealTarget = Int(idealInPos)
            let inStart: Int

            if let previous = previousActualStart {
                // "그냥 hop만큼 이어서 읽었다면 나왔을 파형"(참조 구간)과 가장 비슷한 파형을
                // 원하는 위치(idealTarget) 근처에서 찾는다 — 영교차점 하나만 보는 것과 달리,
                // 파형 전체의 모양을 비교하기 때문에 순음처럼 여러 주기가 거의 똑같이 생긴
                // 신호에서도 "아무 주기나" 고르는 모호함 없이 자연스러운 위상으로 이어붙인다.
                let referenceStart = previous + hop
                inStart = bestMatchingOffset(
                    in: samples,
                    referenceStart: referenceStart,
                    searchCenter: idealTarget,
                    searchRadius: searchRadius,
                    compareLength: hop
                )
            } else {
                inStart = idealTarget
            }
            previousActualStart = inStart

            if inStart >= 0 && inStart + grainSize <= samples.count {
                for i in 0..<grainSize {
                    let w = window[i]
                    let index = Int(outPos) + i
                    output[index] += samples[inStart + i] * w
                    weight[index] += w
                }
            }
            outPos += Double(hop)
            idealInPos += inputHop
        }

        // 겹쳐진 구간은 창(window) 값이 여러 번 더해져 커지므로, 누적된 가중치로 나눠서 정규화한다.
        for i in 0..<output.count where weight[i] > 0.0001 {
            output[i] /= weight[i]
        }

        return Array(output.prefix(outputLength))
    }

    /// `referenceStart` 위치의 파형(`compareLength` 길이)과 가장 비슷한(상관관계가 가장 큰) 구간을
    /// `searchCenter` 근처 ±`searchRadius` 범위에서 찾아 그 시작 위치를 반환한다 — WSOLA의 핵심.
    /// "비슷하다"는 건 단순히 부호가 바뀌는 지점(영교차) 하나가 아니라, 두 구간을 곱해서 더한 값
    /// (내적)이 가장 큰 경우로 정의한다 — 파형 모양 전체가 가장 잘 겹치는 위치를 찾는 것.
    private static func bestMatchingOffset(
        in samples: [Float],
        referenceStart: Int,
        searchCenter: Int,
        searchRadius: Int,
        compareLength: Int
    ) -> Int {
        guard referenceStart >= 0, referenceStart + compareLength <= samples.count else {
            return max(0, min(searchCenter, samples.count - 1))
        }

        let lowerBound = max(0, searchCenter - searchRadius)
        let upperBound = min(samples.count - compareLength, searchCenter + searchRadius)
        guard lowerBound <= upperBound else { return max(0, min(searchCenter, samples.count - 1)) }

        var bestOffset = lowerBound
        var bestScore = -Float.greatestFiniteMagnitude

        for candidate in lowerBound...upperBound {
            var score: Float = 0
            for i in 0..<compareLength {
                score += samples[referenceStart + i] * samples[candidate + i]
            }
            if score > bestScore {
                bestScore = score
                bestOffset = candidate
            }
        }
        return bestOffset
    }

    /// 반달 모양 창(Hann window) — 그레인의 시작과 끝을 0으로 부드럽게 줄여서, 겹쳐 더할 때
    /// 이음매에서 클릭음(불연속)이 나지 않게 한다.
    ///
    /// 분모를 `size`(주기형)로 쓴다 — `size - 1`(대칭형, 양 끝이 정확히 0)을 쓰면 75% 오버랩으로
    /// 겹쳐 더했을 때 창들의 합이 완전히 일정(COLA, constant overlap-add)하지 않아서 미세한
    /// 진폭 출렁임이 생긴다. 주기형으로 쓰면 겹친 창의 합이 상수가 되어 이 문제가 사라진다.
    private static func hannWindow(size: Int) -> [Float] {
        guard size > 1 else { return [1.0] }
        return (0..<size).map { i in
            Float(0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(size)))
        }
    }

    // MARK: - 2단계: 리샘플링(선형 보간)

    static func resample(samples: [Float], rate: Double) -> [Float] {
        guard rate > 0 else { return samples }
        let outputLength = max(1, Int(Double(samples.count) / rate))
        var output = [Float](repeating: 0, count: outputLength)

        for i in 0..<outputLength {
            let sourcePosition = Double(i) * rate
            let index0 = Int(sourcePosition)
            let fraction = Float(sourcePosition - Double(index0))

            if index0 + 1 < samples.count {
                output[i] = samples[index0] * (1 - fraction) + samples[index0 + 1] * fraction
            } else if index0 < samples.count {
                output[i] = samples[index0]
            }
        }
        return output
    }
}
