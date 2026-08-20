import AVFoundation

/// 모노 `[Float]` 버퍼 하나를 트는 최소 구성 재생기 — 어떤 샘플 배열이든 상관없이 재생만
/// 한다(성부/팬/리버브 없음). `VoiceClipPlayer`가 쓰던 것과 같은 검증된 패턴(단일 노드,
/// `completionCallbackType: .dataPlayedBack`)만 남겼다.
///
/// 116절에서 화음 재생 인프라(`VoiceClipPlayer` — 다중 트랙/pan/리버브)를 통째로 지우면서
/// 재생 버튼 자체가 없어졌던 걸, 녹음 원본을 다시 들어볼 수 있게 새로 만들었다(`PracticeView`의
/// `recordingPlayer` 인스턴스). 120절부터는 같은 타입을 두 번째 인스턴스(`harmonyPlayer`)로
/// 재사용해 `SynthesizedHarmonyTrackBuilder`가 만든 합성 화음 믹스도 재생한다 — 이 타입
/// 자체엔 "녹음"이라는 특정 의미가 없어서(그냥 버퍼 재생기) 새 타입을 또 만들 필요가 없었다.
final class RecordingPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isAttached = false
    private var configuredSampleRate: Double?

    func play(samples: [Float], sampleRate: Double, onFinished: (() -> Void)? = nil) throws {
        guard !samples.isEmpty else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        if !isAttached {
            engine.attach(player)
            isAttached = true
        }
        // "다시 녹음"처럼 마이크 세션이 재구성되면 실제 하드웨어 샘플레이트가 달라질 수 있다 —
        // 그럴 때만 연결을 다시 맺는다(49절에서 겪은 것과 같은 패턴).
        if configuredSampleRate != sampleRate {
            if engine.isRunning { engine.stop() }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configuredSampleRate = sampleRate
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            buffer.floatChannelData?[0].update(from: baseAddress, count: samples.count)
        }

        // completionCallbackType을 .dataPlayedBack으로 지정해야 "버퍼를 재생 큐에 넘겼다"가
        // 아니라 "실제로 스피커에서 소리가 다 나갔다" 시점에 콜백이 온다.
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async { onFinished?() }
        }
        player.play()
    }

    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
    }
}
