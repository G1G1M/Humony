import Foundation

/// 오디오 버퍼의 볼륨을 다루는 순수 함수 모음.
///
/// 2026-08-20: 화음(피치시프트/믹싱) 관련 함수(`normalize`/`applyFadeInOut`/`applyGain`/
/// `mixToStereo`)는 화음 API 전체 제거와 함께 정리했다 — 지금 남은 `normalizeLoudness`만
/// 녹음 분석 직전 정규화(화음과 무관, 기기별 마이크 게인 차이 보정)에 계속 쓰인다.
enum AudioGain {

    /// 버퍼의 RMS(전체 평균 에너지, 체감 음량에 훨씬 가까운 지표)가 `targetRMS`가 되도록 스케일한다.
    /// 사람 목소리는 순간적인 피크(숨소리, 파열음, 비브라토 정점)가 지속되는 소리보다 훨씬
    /// 커서(크레스트 팩터가 큼), 피크만 맞추면 그 순간만 크고 나머지는 여전히 조용하게 들린다.
    /// RMS를 기준으로 올리면 전체적으로 확실히 크게 들리지만, 그 대신 순간 피크가 1.0을
    /// 넘어(클리핑) 찢어질 수 있어서 `peakCeiling`으로 다시 한 번 상한을 걸고, 둘 중 더 작은
    /// (보수적인) 게인을 최종적으로 쓴다.
    ///
    /// 녹음 종료 직후 분석 직전에 적용해서(`PracticeView+Capture.swift`), 기기별 마이크
    /// 원본 게인 차이(예: 아이패드가 아이폰보다 훨씬 조용하게 들어옴)에 이후 파이프라인
    /// (VAD/YIN)이 휘둘리지 않게 한다.
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
}
