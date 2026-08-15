import Accelerate
import Foundation

/// YIN 알고리즘 기반 기본 주파수(F0) 검출기.
/// 참고: de Cheveigné & Kawahara, "YIN, a fundamental frequency estimator for speech and music" (2002)
enum YINPitchDetector {

    struct PitchCandidate {
        let frequency: Double     // Hz
        let confidence: Double    // 0(불확실)~1(확실). CMNDF 값이 낮을수록(골이 깊을수록) 확실함.
    }

    struct Configuration {
        var minFrequency: Double = 80.0     // 낮은 남성 저음까지 커버
        var maxFrequency: Double = 1000.0   // 여성 고음 포함 보컬 대역
        // YIN 논문 권장 범위(0.10~0.15). 낮을수록 오탐(잡음을 음정으로 착각)은 줄지만 약한 소리를 놓치기 쉬움.
        var threshold: Double = 0.15

        static let `default` = Configuration()
    }

    /// - Returns: 검출된 피치 후보 배열. 지금은 최대 1개(YIN)만 반환하지만,
    ///   추후 pYIN(여러 후보 + 확률)으로 확장할 때 시그니처를 바꾸지 않아도 되도록 배열로 설계했다.
    static func detectPitch(
        samples: [Float],
        sampleRate: Double,
        configuration: Configuration = .default
    ) -> [PitchCandidate] {
        let n = samples.count
        // 버퍼를 절반으로 나눠 앞쪽은 상관(correlation) 윈도우, 뒤쪽은 tau 탐색 범위로 쓴다.
        let tauMax = n / 2
        guard tauMax > 2 else { return [] }

        let tauMin = max(2, Int((sampleRate / configuration.maxFrequency).rounded()))
        let tauSearchMax = min(tauMax, Int((sampleRate / configuration.minFrequency).rounded()))
        guard tauMin < tauSearchMax else { return [] }

        let difference = computeDifferenceFunction(samples: samples, tauMax: tauMax)
        let cmndf = cumulativeMeanNormalizedDifference(difference)

        guard let tauEstimate = findAbsoluteThresholdMinimum(
            cmndf: cmndf,
            tauMin: tauMin,
            tauMax: tauSearchMax,
            threshold: configuration.threshold
        ) else {
            return []
        }

        let refinedTau = parabolicInterpolation(cmndf: cmndf, aroundTau: tauEstimate)
        guard refinedTau > 0 else { return [] }

        let frequency = sampleRate / refinedTau
        let confidence = max(0, 1.0 - cmndf[tauEstimate])

        return [PitchCandidate(frequency: frequency, confidence: confidence)]
    }

    // MARK: - Step 1: Difference function (자기상관 기반)

    /// d(tau) = energy(윈도우) + energy(tau만큼 밀린 윈도우) - 2 * 상관(tau)
    /// 세 항 모두 vDSP_dotpr(벡터 내적)로 계산한다 — 이중 for-loop 대신
    /// Accelerate가 벡터화된 내적을 계산하게 해서 실시간 처리에 필요한 성능을 확보한다.
    private static func computeDifferenceFunction(samples: [Float], tauMax: Int) -> [Double] {
        let w = samples.count - tauMax
        var difference = [Double](repeating: 0, count: tauMax + 1)

        samples.withUnsafeBufferPointer { buffer in
            let base = buffer.baseAddress!

            var windowEnergy: Float = 0
            vDSP_dotpr(base, 1, base, 1, &windowEnergy, vDSP_Length(w))

            for tau in 1...tauMax {
                var shiftedEnergy: Float = 0
                vDSP_dotpr(base + tau, 1, base + tau, 1, &shiftedEnergy, vDSP_Length(w))

                var crossCorrelation: Float = 0
                vDSP_dotpr(base, 1, base + tau, 1, &crossCorrelation, vDSP_Length(w))

                difference[tau] = Double(windowEnergy + shiftedEnergy - 2 * crossCorrelation)
            }
        }
        return difference
    }

    // MARK: - Step 2: Cumulative mean normalized difference function (CMNDF)

    /// d'(0) = 1로 정의하고, tau >= 1에서는 그때까지의 누적 평균으로 나눠 정규화한다.
    /// 이렇게 하면 tau가 작을 때 우연히 값이 작아 보이는 걸 억제하고,
    /// 실제 주기에서만 뚜렷한 골(dip)이 드러난다 (YIN 논문 2절).
    private static func cumulativeMeanNormalizedDifference(_ difference: [Double]) -> [Double] {
        var cmndf = [Double](repeating: 1.0, count: difference.count)
        var runningSum = 0.0
        for tau in 1..<difference.count {
            runningSum += difference[tau]
            cmndf[tau] = runningSum == 0 ? 1.0 : difference[tau] * Double(tau) / runningSum
        }
        return cmndf
    }

    // MARK: - Step 3: Absolute threshold

    /// threshold보다 처음 작아지는 지점을 찾고, 거기서 계속 작아지는 동안 따라가서 국소 최소값(local minimum)을 잡는다.
    /// 첫 threshold 통과 지점을 그대로 쓰면 아직 골 바닥에 도달하기 전일 수 있다 (YIN 논문 4절).
    private static func findAbsoluteThresholdMinimum(
        cmndf: [Double],
        tauMin: Int,
        tauMax: Int,
        threshold: Double
    ) -> Int? {
        var tau = tauMin
        while tau < tauMax {
            if cmndf[tau] < threshold {
                while tau + 1 < tauMax && cmndf[tau + 1] < cmndf[tau] {
                    tau += 1
                }
                return tau
            }
            tau += 1
        }
        return nil
    }

    // MARK: - Step 4: Parabolic interpolation (sub-sample 정밀도)

    /// 정수 tau만 쓰면 주파수 해상도가 sampleRate/tau 단위로 계단식으로 끊긴다.
    /// tau 주변 3개 점(tau-1, tau, tau+1)에 포물선을 맞춰 꼭짓점을 구하면
    /// 정수 사이의 실수 tau를 추정할 수 있고, 이게 ±10 cent 정확도 목표에 필요하다.
    private static func parabolicInterpolation(cmndf: [Double], aroundTau tau: Int) -> Double {
        guard tau > 0 && tau < cmndf.count - 1 else { return Double(tau) }

        let s0 = cmndf[tau - 1]
        let s1 = cmndf[tau]
        let s2 = cmndf[tau + 1]

        let denominator = 2 * s1 - s2 - s0
        guard denominator != 0 else { return Double(tau) }

        let shift = 0.5 * (s2 - s0) / denominator
        return Double(tau) + shift
    }
}
