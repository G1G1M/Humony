import Accelerate
import Foundation

/// 에너지(평균 파워) 기반 음성 활동 검출기(VAD).
/// 무음/저에너지 구간을 걸러서 YINPitchDetector가 잡음을 음정으로 잘못 검출하는 걸 막는다.
enum VoiceActivityDetector {

    struct Configuration {
        // 평균 파워(mean square) 임계값. 대략 RMS 0.01(약 -40dBFS)에 해당 —
        // 조용한 실내 배경 소음보다는 높고, 작게 흥얼거리는 소리보다는 낮게 잡은 시작값.
        // 실기기 검증 단계(phase-1-yin-prototype.md 검증 방법 3번)에서 실측 후 조정 필요.
        var energyThreshold: Float = 0.0001

        static let `default` = Configuration()
    }

    /// - Returns: 이 프레임에 음성(또는 노래)이 활동 중인지 여부.
    static func isVoiceActive(samples: [Float], configuration: Configuration = .default) -> Bool {
        guard !samples.isEmpty else { return false }

        // vDSP_measqv: 샘플 제곱의 평균(mean square) = 신호 평균 파워.
        // RMS(= sqrt(meanSquare))를 따로 구하지 않는 이유: 임계값과 비교만 하면 되므로
        // 제곱근 계산을 생략해서 연산을 아낀다.
        var meanSquare: Float = 0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))

        return meanSquare > configuration.energyThreshold
    }
}
