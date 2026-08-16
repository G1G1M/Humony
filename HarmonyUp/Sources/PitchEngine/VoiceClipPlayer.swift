import AVFoundation

/// 이미 만들어진 오디오 데이터([Float] 배열, 예: 피치 시프트된 사용자 목소리)를 한 번 재생한다.
/// TonePlayer가 매 샘플을 실시간으로 계산해서 합성하는 반면, 이건 완성된 파형을 그대로 재생만 한다.
final class VoiceClipPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isConfigured = false

    func play(samples: [Float], sampleRate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        if !isConfigured {
            engine.attach(player)
            // format: nil로 연결하면 엔진이 믹서의 기본 포맷(보통 스테레오, 2채널)으로 연결해버려서,
            // 나중에 모노(1채널) 버퍼를 재생하려 하면 "채널 수가 다르다"는 충돌로 앱이 죽는다
            // (_outputFormat.channelCount == buffer.format.channelCount 단언 실패).
            // 버퍼와 정확히 같은 포맷(모노)으로 명시적으로 연결해서 이 불일치를 없앤다.
            engine.connect(player, to: engine.mainMixerNode, format: format)
            isConfigured = true
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
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
