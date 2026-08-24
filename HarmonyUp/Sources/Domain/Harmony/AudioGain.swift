import Foundation

/// 오디오 버퍼의 볼륨을 다루는 순수 함수 모음.
///
/// 2026-08-20: 화음(피치시프트/믹싱) 관련 함수는 화음 API 전체 제거(116절)와 함께 한 번
/// 정리했다가, 화음을 합성음으로 재설계(120절)하면서 그중 `applyFadeInOut`(스텝 경계 클릭
/// 방지)과 `mix`(성부 합산)를 되살렸다.
///
/// 145절에 `mixToStereo`/`normalizeStereo`가 돌아왔다 — 성부를 좌우로 벌리는 게 "여러 명이
/// 같이 부르는" 느낌의 큰 축인데, 그동안 `ChordGenerator.Interval.pan`에 값만 정의해두고
/// 정작 쓰는 곳이 한 군데도 없어서 네 성부가 전부 모노 정중앙에 포개져 재생되고 있었다.
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

    /// 스테레오 믹스에 넣을 성부 하나 — 샘플과 그 성부를 놓을 좌우 위치.
    struct PannedTrack {
        let samples: [Float]
        /// -1 = 완전 왼쪽, 0 = 정중앙, 1 = 완전 오른쪽.
        let pan: Float
    }

    /// 성부들을 좌우로 벌려 스테레오 두 채널로 섞는다.
    ///
    /// **등파워(equal-power) 팬 법칙을 쓰는 이유**: 좌우 게인을 `1-x`/`x`로 선형 분배하면
    /// 정중앙에서 각 채널이 0.5씩이라 두 채널 에너지 합(L²+R²)이 0.5로 떨어진다 — 좌우로
    /// 완전히 치우친 성부(1.0)보다 중앙 성부가 √2배 작게 들려서, 팬을 걸었을 뿐인데 리드
    /// 멜로디만 뒤로 물러난 것처럼 된다. 각도를 0~90°로 매핑해 `cos`/`sin`을 쓰면 어느
    /// 위치에서도 L²+R²=1이라 체감 음량이 일정하게 유지된다.
    static func mixToStereo(tracks: [PannedTrack]) -> (left: [Float], right: [Float]) {
        guard let length = tracks.map(\.samples.count).max(), length > 0 else { return ([], []) }

        var left = [Float](repeating: 0, count: length)
        var right = [Float](repeating: 0, count: length)

        for track in tracks {
            let clamped = min(max(track.pan, -1), 1)
            // -1...1 → 0...(π/2)
            let angle = (clamped + 1) * 0.5 * (Float.pi / 2)
            let leftGain = cos(angle)
            let rightGain = sin(angle)

            for i in 0..<track.samples.count {
                let sample = track.samples[i]
                left[i] += sample * leftGain
                right[i] += sample * rightGain
            }
        }
        return (left, right)
    }

    /// 스테레오 버퍼의 음량을 맞춘다 — `normalizeLoudness`의 스테레오 판.
    ///
    /// **채널마다 따로 정규화하면 안 되는 이유**: 채널별로 RMS를 재서 각자 맞추면 조용한
    /// 쪽이 더 크게 증폭돼 좌우 밸런스가 통째로 무너진다(팬을 걸어둔 의미가 사라진다).
    /// 두 채널을 하나의 신호로 보고 게인을 한 번만 계산해서 **양쪽에 똑같이** 적용한다.
    static func normalizeStereo(
        left: [Float],
        right: [Float],
        targetRMS: Float = 0.25,
        peakCeiling: Float = 0.98
    ) -> (left: [Float], right: [Float]) {
        guard !left.isEmpty || !right.isEmpty else { return (left, right) }

        let totalCount = left.count + right.count
        let sumOfSquares = left.reduce(Float(0)) { $0 + $1 * $1 } + right.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sumOfSquares / Float(totalCount)).squareRoot()
        guard rms > 0.0001 else { return (left, right) }

        var gain = targetRMS / rms
        let peak = max(left.map { abs($0) }.max() ?? 0, right.map { abs($0) }.max() ?? 0)
        if peak > 0.0001 {
            gain = min(gain, peakCeiling / peak)
        }
        return (left.map { $0 * gain }, right.map { $0 * gain })
    }
}
