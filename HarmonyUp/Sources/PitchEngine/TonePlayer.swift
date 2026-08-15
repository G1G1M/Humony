import AVFoundation

/// 지정한 주파수의 순수 사인파를 계속 재생한다.
/// 화음 제안(ChordGenerator 결과)이 실제로 맞는지 귀로 확인하고,
/// 나중에는 이 소리를 "따라 불러야 할 목표음"으로 쓴다.
final class TonePlayer {

    private let engine = AVAudioEngine()
    private var isConfigured = false

    // 스피커로 재생한 소리가 마이크로 다시 들어가 YIN/VAD를 방해할 수 있으므로 작게 잡는다.
    private let amplitude: Float = 0.2

    // 오디오 렌더 스레드(실시간)에서 읽고, 메인 스레드(setFrequency)에서 쓴다.
    // 둘 다 Double 하나만 다루는 단순 대입이라 프로토타입 수준에서는 락 없이도 괜찮지만,
    // 정식 버전에서는 정확한 스레드 안전성 보장이 필요하다.
    private var frequency: Double = 440.0
    private var phase: Double = 0

    /// 그래프(오디오 노드 연결)는 최초 1번만 만들고, 이후 start/stop은 엔진을 멈췄다 재개하는 식으로 처리한다 —
    /// 매번 새로 attach/connect하면 이전 재생에서 쓰던 노드가 그래프에 그대로 남아
    /// 재생을 반복할수록 소리가 겹쳐 쌓이는 버그가 생긴다.
    func start() throws {
        if !isConfigured {
            configure()
            isConfigured = true
        }
        guard !engine.isRunning else { return }
        try engine.start()
    }

    private func configure() {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let phaseIncrement = 2.0 * Double.pi * self.frequency / sampleRate

            for frame in 0..<Int(frameCount) {
                let sample = Float(sin(self.phase)) * self.amplitude
                self.phase += phaseIncrement
                if self.phase > 2.0 * Double.pi { self.phase -= 2.0 * Double.pi }

                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    /// 재생 중인 톤의 주파수를 바꾼다 (예: 새로 제안된 화음 음으로 전환).
    func setFrequency(_ newFrequency: Double) {
        frequency = newFrequency
    }

    func stop() {
        guard engine.isRunning else { return }
        engine.pause()
    }
}
