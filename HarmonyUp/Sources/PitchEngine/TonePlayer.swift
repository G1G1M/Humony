import AVFoundation

/// 지정한 주파수의 톤을 계속 재생한다.
/// 화음 제안(ChordGenerator 결과)이 실제로 맞는지 귀로 확인하고,
/// 나중에는 이 소리를 "따라 불러야 할 목표음"으로 쓴다.
final class TonePlayer {

    private let engine = AVAudioEngine()
    private var isConfigured = false

    // 마이크 피드백을 우려해 처음엔 0.15로 낮게 잡았는데 실기기에서 너무 안 들려서 올림.
    // 배음까지 더해 /1.45로 정규화한 뒤 곱하므로 0.6이어도 클리핑(1.0 초과)까지는 여유가 있다.
    private let peakAmplitude: Float = 0.6

    // 오디오 렌더 스레드(실시간)에서 읽고, 메인 스레드(setFrequency)에서 쓴다.
    // 둘 다 Double/Float 하나만 다루는 단순 대입이라 프로토타입 수준에서는 락 없이도 괜찮지만,
    // 정식 버전에서는 정확한 스레드 안전성 보장이 필요하다.
    private var frequency: Double = 440.0
    private var phase: Double = 0

    // 시작/정지 시 소리가 뚝 끊기지 않고 부드럽게 커지고/작아지도록 하는 볼륨 값(0~1)과 그 목표.
    // envelopeStep만큼씩 목표를 향해 매 샘플 이동한다 — 44.1kHz에서 step 0.0008이면
    // 1/0.0008 ≈ 1250 샘플, 약 28ms 만에 0→1(또는 1→0)에 도달한다.
    private var envelope: Float = 0
    private var envelopeTarget: Float = 0
    private let envelopeStep: Float = 0.0008

    /// 그래프(오디오 노드 연결)는 최초 1번만 만들고, 이후 start/stop은 엔진을 멈췄다 재개하는 식으로 처리한다 —
    /// 매번 새로 attach/connect하면 이전 재생에서 쓰던 노드가 그래프에 그대로 남아
    /// 재생을 반복할수록 소리가 겹쳐 쌓이는 버그가 생긴다.
    func start() throws {
        if !isConfigured {
            configure()
            isConfigured = true
        }
        envelopeTarget = 1
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
                // 배음이 하나도 없는 순수 사인파는 신호음/삐 소리처럼 들린다.
                // 2배음·3배음을 약하게 섞는 간단한 가산 합성으로 조금 더 악기 소리에 가깝게 만든다.
                let fundamental = sin(self.phase)
                let secondHarmonic = sin(self.phase * 2) * 0.3
                let thirdHarmonic = sin(self.phase * 3) * 0.15
                let raw = Float(fundamental + secondHarmonic + thirdHarmonic) / 1.45 // 배음을 더해서 커진 진폭을 다시 정규화

                // envelope을 목표치로 조금씩 옮겨서, 재생을 시작/정지할 때 뚝 끊기는 클릭음이 나지 않게 한다.
                if self.envelope < self.envelopeTarget {
                    self.envelope = min(self.envelopeTarget, self.envelope + self.envelopeStep)
                } else if self.envelope > self.envelopeTarget {
                    self.envelope = max(self.envelopeTarget, self.envelope - self.envelopeStep)
                }

                let sample = raw * self.envelope * self.peakAmplitude
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
        envelopeTarget = 0
        // 페이드 아웃(약 28ms)이 끝날 때까지 기다렸다가 엔진을 멈춘다 — 볼륨이 0으로 다 내려가기 전에
        // engine.pause()를 부르면 그 자체로 소리가 뚝 끊기는 클릭음이 나기 때문.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.envelopeTarget == 0, self.engine.isRunning else { return }
            self.engine.pause()
        }
    }
}
