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

    /// 여러 트랙(예: 원음 + 3도 + 5도로 각각 피치 시프트한 목소리)을 하나로 합친 뒤 정규화한다.
    /// 트랙마다 길이가 살짝 다를 수 있어서(피치 시프트 특성상) 가장 짧은 길이에 맞춘다.
    static func mixAndNormalize(_ tracks: [[Float]], targetPeak: Float = 0.95) -> [Float] {
        let nonEmptyTracks = tracks.filter { !$0.isEmpty }
        guard let minLength = nonEmptyTracks.map(\.count).min(), minLength > 0 else { return [] }

        var mixed = [Float](repeating: 0, count: minLength)
        for track in nonEmptyTracks {
            for i in 0..<minLength {
                mixed[i] += track[i]
            }
        }
        return normalize(mixed, targetPeak: targetPeak)
    }
}
