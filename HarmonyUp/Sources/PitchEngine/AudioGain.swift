import Foundation

/// 오디오 버퍼의 볼륨을 다루는 순수 함수 모음.
/// AVAudioPlayerNode의 volume 프로퍼티는 0~1 범위라 원본보다 "더 크게"는 못 키운다 —
/// 실제로 소리를 키우려면 샘플 값 자체를 스케일업하는 디지털 게인이 필요하다.
enum AudioGain {

    /// 버퍼의 최대 진폭(피크)이 `targetPeak`가 되도록 전체를 스케일한다.
    /// 마이크로 녹음한 목소리는 보통 피크가 한참 낮게(예: 0.1~0.3) 들어오는데, 그걸 거의
    /// 꽉 차게(기본 0.95, 클리핑 방지용으로 1.0보다 살짝 낮게) 키워서 체감 음량을 최대화한다.
    static func normalize(_ samples: [Float], targetPeak: Float = 0.95) -> [Float] {
        guard let peak = samples.map({ abs($0) }).max(), peak > 0.0001 else { return samples }
        let gain = targetPeak / peak
        return samples.map { $0 * gain }
    }

    /// 버퍼의 RMS(전체 평균 에너지, 체감 음량에 훨씬 가까운 지표)가 `targetRMS`가 되도록 스케일한다.
    /// `normalize`(피크 기준)와의 차이: 사람 목소리는 순간적인 피크(숨소리, 파열음, 비브라토
    /// 정점)가 지속되는 소리보다 훨씬 커서(크레스트 팩터가 큼), 피크만 0.95로 맞추면 그 순간만
    /// 크고 나머지는 여전히 조용하게 들린다 — "녹음한 목소리가 음성 메모 앱보다 작게 들린다"는
    /// 피드백의 원인이 이거였다. RMS를 기준으로 올리면 전체적으로 확실히 크게 들리지만, 그 대신
    /// 순간 피크가 1.0을 넘어(클리핑) 찢어질 수 있어서 `peakCeiling`으로 다시 한 번 상한을 걸고,
    /// 둘 중 더 작은(보수적인) 게인을 최종적으로 쓴다.
    static func normalizeLoudness(_ samples: [Float], targetRMS: Float = 0.25, peakCeiling: Float = 0.98) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sumOfSquares / Float(samples.count)).squareRoot()
        guard rms > 0.0001 else { return samples }

        var gain = targetRMS / rms
        if let peak = samples.map({ abs($0) }).max(), peak > 0.0001 {
            gain = min(gain, peakCeiling / peak)
        }
        return samples.map { $0 * gain }
    }

    /// 버퍼의 맨 앞과 맨 뒤를 짧게 선형으로 0까지 줄인다("페이드 인/아웃") — 재생 시작/끝에서
    /// 나는 "뚝" 하는 클릭음을 없앤다. 녹음 버퍼는 원본 파형의 임의 지점에서 시작/끝나기 때문에,
    /// 그 경계에서 값이 0이 아닌 채로 갑자기 시작되거나 끊기면 스피커에서 그 불연속 자체가
    /// 짧은 클릭음으로 들린다.
    static func applyFadeInOut(_ samples: [Float], fadeSampleCount: Int) -> [Float] {
        applyFadeInOut(samples, fadeInCount: fadeSampleCount, fadeOutCount: fadeSampleCount)
    }

    /// 위 `applyFadeInOut(_:fadeSampleCount:)`의 비대칭 버전 — 앞/뒤 페이드 길이를 따로
    /// 지정한다(0이면 그쪽은 아예 페이드 없음). `harmonizedTrack`이 "이어 부른 여러 음을 하나로
    /// 이어 붙인 구간"(런) 전체를 한 번에 피치시프트할 때, 그 런의 맨 처음에만 페이드 인,
    /// 맨 끝에만 페이드 아웃을 걸고 싶어서 추가했다 — 런 안쪽(원래 음 경계였던 자리)에는
    /// 페이드를 안 걸어야 진짜로 끊김 없이 이어 들린다(안쪽에도 짧게라도 페이드를 걸면
    /// 그 자리마다 미세한 "훅" 하는 골이 남는다).
    static func applyFadeInOut(_ samples: [Float], fadeInCount: Int, fadeOutCount: Int) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let maxHalf = samples.count / 2
        var result = samples

        let inCount = min(fadeInCount, maxHalf)
        if inCount > 0 {
            for i in 0..<inCount {
                result[i] *= Float(i) / Float(inCount)
            }
        }
        let outCount = min(fadeOutCount, maxHalf)
        if outCount > 0 {
            for i in 0..<outCount {
                result[result.count - 1 - i] *= Float(i) / Float(outCount)
            }
        }
        return result
    }

    /// 성부별 상대 음량 차등(믹스 밸런스, `ChordGenerator.Interval.gain`)을 적용한다 —
    /// `normalizeLoudness`로 모든 트랙을 이미 같은 라우드니스로 맞춘 뒤, 이 배율로 상대적인
    /// 크고 작음만 마지막에 미세 조정하는 용도다(예: 바버샵 보이싱처럼 3도를 살짝 배경으로).
    static func applyGain(_ samples: [Float], factor: Float) -> [Float] {
        samples.map { $0 * factor }
    }
}
