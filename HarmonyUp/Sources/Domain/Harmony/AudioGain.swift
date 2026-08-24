import Foundation

/// 오디오 버퍼의 볼륨을 다루는 순수 함수 모음.
///
/// 2026-08-20: 화음(피치시프트/믹싱) 관련 함수는 화음 API 전체 제거(116절)와 함께 한 번
/// 정리했다가, 화음을 합성음으로 재설계(120절)하면서 그중 `applyFadeInOut`(스텝 경계 클릭
/// 방지)과 `mix`(성부 합산, 새로 추가 — 예전엔 pan까지 반영하는 `mixToStereo`였지만 지금은
/// 모노만 필요해서 더 단순한 형태로 다시 만들었다)를 되살렸다. `applyGain`/`mixToStereo`는
/// pan/성부별 개별 음량 조정이 필요해지면 그때 다시 가져온다(git history 96987e2^ 참고).
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

    /// 버퍼의 맨 앞과 맨 뒤를 짧게 선형으로 0까지 줄인다("페이드 인/아웃") — 재생 시작/끝에서
    /// 나는 "뚝" 하는 클릭음을 없앤다. `SynthesizedHarmonyTrackBuilder`가 스텝(음표)마다
    /// 이걸 걸어서, 합성음이 갑자기 켜지고 꺼질 때 나는 클릭을 막는다.
    static func applyFadeInOut(_ samples: [Float], fadeSampleCount: Int) -> [Float] {
        guard !samples.isEmpty, fadeSampleCount > 0 else { return samples }
        let count = min(fadeSampleCount, samples.count / 2)
        guard count > 0 else { return samples }

        var result = samples
        for i in 0..<count {
            let factor = Float(i) / Float(count)
            result[i] *= factor
            result[result.count - 1 - i] *= factor
        }
        return result
    }

    /// 길이가 같은 여러 트랙(성부)을 샘플 단위로 그대로 더한다. `SynthesizedHarmonyTrackBuilder`가
    /// 각 성부(멜로디/베이스/3도/5도)를 원본 녹음과 같은 길이로 만들어주므로, 여기서는 팬/게인
    /// 조정 없이 단순 합산만 한다 — 합산 후 `normalizeLoudness`로 전체 음량을 맞추면 된다.
    static func mix(tracks: [[Float]]) -> [Float] {
        guard let length = tracks.map(\.count).max(), length > 0 else { return [] }
        var output = [Float](repeating: 0, count: length)
        for track in tracks {
            for i in 0..<track.count {
                output[i] += track[i]
            }
        }
        return output
    }
}
