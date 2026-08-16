import AVFoundation

/// 이미 만들어진 오디오 데이터([Float] 배열, 예: 피치 시프트된 사용자 목소리)를 한 번 재생한다.
/// TonePlayer가 매 샘플을 실시간으로 계산해서 합성하는 반면, 이건 완성된 파형을 그대로 재생만 한다.
final class VoiceClipPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isConfigured = false

    func play(samples: [Float], sampleRate: Double) throws {
        if !isConfigured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            isConfigured = true
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            buffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()
    }

    func stop() {
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
    }
}
