import Accelerate
import Foundation

/// 녹음된 오디오의 재생 속도(길이)는 그대로 유지하면서 피치만 바꾼다.
/// "내 목소리로 화음 만들기" 기능의 최초 구현(92b4585) — WSOLA(Waveform-Similarity
/// Overlap-Add)로 시간축을 늘이거나 줄인 뒤 리샘플링해서 피치를 옮긴다.
///
/// **되살린 이유(2026-08-20)**: 이후 `PitchShifterPSOLA`(포먼트 보존 재작성) →
/// `PitchShifterWorld`(WORLD 보코더)로 두 번 교체됐는데, WORLD로도 "화음이 이상하게
/// 들린다"는 제보가 계속돼서 — 정작 어느 알고리즘이 이 앱의 화음 파이프라인(짧은 세그먼트
/// 단위 피치시프트, 베이스/3도/5도 동시 재생)에 제일 잘 맞는지 실기기로 직접 A/B 비교해보기
/// 위해 git 히스토리(`c94288b^`, PSOLA로 교체되기 직전 최종 다듬어진 버전)에서 그대로
/// 복원했다. **주의**: 이 알고리즘은 리샘플링이 피치와 포먼트를 같은 비율로 함께 바꿔서
/// "화음이 기계음 같다"는 피드백으로 교체됐던 전적이 있다 — `formantRatio` 개념 자체가
/// 없다(WORLD 전용, 여기선 지원 안 함).
enum PitchShifterWSOLA {

    /// - Parameters:
    ///   - samples: 원본 오디오(모노, [-1, 1] 범위)
    ///   - pitchRatio: 목표 주파수 / 원래 주파수. 1보다 크면 높은 음(예: 장3도 위 = 2^(4/12)).
    ///   - expectedFrequency: 원본 음성의 대략적인 기본 주파수(Hz)를 알고 있다면 넘긴다.
    ///     WSOLA의 그레인 탐색 반경을 피치 주기 이하로 제한해서 "주기 하나를 잘못 골라
    ///     미세하게 음이 흔들리는" 현상(아래 `bestMatchingOffset` 설명 참고)을 줄인다.
    ///     모르면 nil — 기존 동작(탐색 반경 = hop)으로 동작한다.
    /// - Returns: 길이는 원본과 거의 같고, 피치만 pitchRatio배 된 오디오.
    static func shift(samples: [Float], pitchRatio: Double, sampleRate: Double, expectedFrequency: Double? = nil) -> [Float] {
        guard !samples.isEmpty, pitchRatio > 0 else { return samples }

        // 1단계: 길이를 pitchRatio배로 늘이거나 줄인다(피치는 그대로 유지, WSOLA).
        // 2단계: 그 결과를 pitchRatio배 빠르기로 리샘플링한다 — 리샘플링은 피치와 길이를
        // 동시에 pitchRatio배 하기 때문에, 1단계에서 미리 늘려둔 길이가 다시 원래 길이로
        // 돌아오면서 피치만 pitchRatio배로 바뀐 결과가 나온다.
        let stretched = timeStretch(samples: samples, factor: pitchRatio, sampleRate: sampleRate, expectedFrequency: expectedFrequency)
        return resample(samples: stretched, rate: pitchRatio)
    }

    // MARK: - 1단계: WSOLA(Waveform-Similarity Overlap-Add) 시간축 늘이기/줄이기

    // 그레인(조각) 하나의 길이. 너무 작으면 음색이 뭉개지고, 너무 크면 겹치는 자연스러움이 떨어진다 —
    // 44.1kHz 기준 약 23ms로, 사람 목소리의 한 피치 주기(수 ms)보다 충분히 길다.
    private static let grainSize = 1024

    // 그레인을 87.5% 겹치게(hop = grainSize/8) 이어붙인다 — 겹침이 클수록 그레인 사이 이음매가
    // 부드러워지고 "지지직"거리는 느낌이 줄어든다. 예전엔 75%(hopDivisor=4)였는데, 탐색 반경이
    // (25절 이후) 피치 주기에 맞춰 hop과 별개로 제한돼 있어서 겹침을 늘려도 그레인당 탐색
    // 비용은 거의 그대로고, 대신 그레인 개수만 늘어난 만큼 창(window) 처리 비용만 조금 늘어난다 —
    // vDSP 벡터화(25절) 이후로는 이 정도 여유가 있다고 판단해 오버랩을 올렸다.
    private static let hopDivisor = 8

    // internal(private 아님)로 열어둔 이유: 유닛테스트에서 1단계(시간축 변형)와 2단계(리샘플링)를
    // 각각 따로 검증해서 버그가 어느 단계에 있는지 격리하기 위함.
    static func timeStretch(samples: [Float], factor: Double, sampleRate: Double? = nil, expectedFrequency: Double? = nil) -> [Float] {
        let hop = grainSize / hopDivisor
        // factor(=pitchRatio)가 1보다 크면(음을 높이려는 경우) 입력을 더 천천히(작은 보폭으로)
        // 읽어서, 출력이 원본보다 길어지게 만든다 — 그래야 2단계 리샘플링 후 원래 길이로 돌아온다.
        let inputHop = Double(hop) / factor

        // 탐색 반경이 피치 한 주기보다 넓으면, 사람 목소리처럼 준주기적인 신호에서 이웃한 주기끼리
        // 파형 모양이 거의 똑같아서 상관관계가 "한 주기 앞/뒤"를 잘못 고르는 경우가 생긴다. 매 그레인마다
        // 이게 왔다갔다하면 결과물의 피치가 미세하게 흔들리는 것처럼 들린다("음이 왔다갔다한다"). 원본의
        // 대략적인 기본 주파수를 알고 있으면, 탐색 반경을 반 주기 이하로 좁혀서 이 오탐 가능성을 줄인다.
        let searchRadius: Int
        if let sampleRate, let expectedFrequency, expectedFrequency > 0 {
            let periodInSamples = sampleRate / expectedFrequency
            searchRadius = max(16, min(hop, Int(periodInSamples / 2)))
        } else {
            searchRadius = hop
        }

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

        // 이 내적(dot product) 계산이 WSOLA에서 가장 무거운 부분이다 — 그레인마다
        // (탐색 반경 x compareLength)번 곱셈+덧셈을 반복한다. Swift for-loop 대신
        // Accelerate(vDSP_dotpr)로 벡터화하면, 컴파일 최적화 수준과 무관하게(디버그
        // 빌드에서도) 하드웨어 SIMD 명령으로 훨씬 빠르게 계산된다.
        samples.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!
            for candidate in lowerBound...upperBound {
                var score: Float = 0
                vDSP_dotpr(base + referenceStart, 1, base + candidate, 1, &score, vDSP_Length(compareLength))
                if score > bestScore {
                    bestScore = score
                    bestOffset = candidate
                }
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

        // rate > 1(3도/5도처럼 음을 높일 때)은 이 단계에서 사실상 다운샘플링이다 — 매 출력
        // 샘플마다 입력을 rate배씩 건너뛰며 읽는다. 다운샘플링 전에 새 나이퀴스트 주파수보다
        // 높은 성분을 걸러두지 않으면 그 성분이 접혀 들어와(에일리어싱) 특히 "쇠소리" 같은
        // 거슬리는 잡음으로 들린다 — 사용자가 "화음이 어색하다"고 느낀 것들 중 상당수가
        // 이 원인일 가능성이 크다(3도/5도가 베이스보다 훨씬 자주 쓰이는 비율이라 더 눈에 띔).
        // rate <= 1(베이스처럼 낮출 때)은 반대로 보간(업샘플링)이라 이 문제가 없다.
        let filtered = rate > 1 ? antiAliasFilter(samples, decimationRate: rate) : samples

        let outputLength = max(1, Int(Double(filtered.count) / rate))
        var output = [Float](repeating: 0, count: outputLength)

        for i in 0..<outputLength {
            let sourcePosition = Double(i) * rate
            let index0 = Int(sourcePosition)
            let fraction = Float(sourcePosition - Double(index0))

            if index0 + 1 < filtered.count {
                output[i] = filtered[index0] * (1 - fraction) + filtered[index0 + 1] * fraction
            } else if index0 < filtered.count {
                output[i] = filtered[index0]
            }
        }
        return output
    }

    /// 다운샘플링 전에 거는 저역통과 필터 — 진짜 sinc 기반 필터 대신 단순 이동평균(박스 필터)을
    /// 쓴 이유는, 감쇠 특성은 덜 날카롭지만(약간의 고음 뭉개짐) 구현이 짧고 인덱스 실수로
    /// 버그가 날 여지가 거의 없어서다(귀로 직접 검증하기 어려운 DSP 코드라 단순함을 우선했다).
    /// 탭 개수를 감쇠 비율(decimationRate)에 맞춰 정해서, 많이 접을수록(다운샘플링 비율이
    /// 클수록) 더 넓게 평균 내 더 많은 고음을 걸러낸다.
    static func antiAliasFilter(_ samples: [Float], decimationRate: Double) -> [Float] {
        guard decimationRate > 1, !samples.isEmpty else { return samples }
        let taps = max(2, Int(decimationRate.rounded()))

        var output = [Float](repeating: 0, count: samples.count)
        var runningSum: Float = 0
        for i in 0..<samples.count {
            runningSum += samples[i]
            if i >= taps { runningSum -= samples[i - taps] }
            let windowSize = Float(min(i + 1, taps))
            output[i] = runningSum / windowSize
        }
        return output
    }
}
