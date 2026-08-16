import AVFoundation

/// 이미 만들어진 오디오 데이터([Float] 배열, 예: 피치 시프트된 사용자 목소리)를 한 번 재생한다.
/// TonePlayer가 매 샘플을 실시간으로 계산해서 합성하는 반면, 이건 완성된 파형을 그대로 재생만 한다.
final class VoiceClipPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let reverb = AVAudioUnitReverb()
    private var isAttached = false
    // 재생 그래프가 지금 어떤 샘플레이트로 연결돼 있는지 — "다시 녹음"처럼 마이크 세션이
    // 재구성될 때마다 실제 하드웨어 샘플레이트가 달라질 수 있어서, 이 값이 바뀌면 연결을
    // 다시 맺어야 한다(아래 설명 참고).
    private var configuredSampleRate: Double?

    /// - Parameter onFinished: 재생이 실제로 스피커까지 다 끝난 뒤 메인 스레드에서 호출된다.
    ///   호출한 쪽이 "지금 화음이 재생 중이다"라는 상태를 정확히 켜고 끌 수 있게 해준다 —
    ///   이게 없으면(예전 버전) 재생이 언제 끝나는지 알 방법이 없어서, 재생 중에도 마이크가
    ///   계속 켜진 채로 남아있는 문제가 있었다(자세한 이유는 `docs/CONCEPTS.md` 26절 참고).
    func play(samples: [Float], sampleRate: Double, onFinished: (() -> Void)? = nil) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        if !isAttached {
            engine.attach(player)
            engine.attach(reverb)
            // 화음 성부들이 다 같은 공간에서 함께 부르는 듯한 일체감을 주는 공유 리버브
            // (docs/CONCEPTS.md 49절) — 세게 걸면 오히려 성부 구분이 흐려지고 "울림 통에서
            // 녹음한 것" 같아지므로, 은은하게(18%)만 섞어서 WORLD 합성의 미세한 기계음 느낌을
            // 가리는 정도로만 쓴다.
            reverb.loadFactoryPreset(.mediumRoom)
            reverb.wetDryMix = 18
            isAttached = true
        }

        // 연결 포맷을 최초 한 번만 고정해뒀더니, "다시 녹음"으로 마이크 세션이 재시작되면서
        // 실제 하드웨어 샘플레이트가 이전 녹음과 달라진 경우(AudioCapture가 매 녹음마다
        // setCategory/setActive를 다시 호출해 세션을 재구성함, docs/CONCEPTS.md 49절) 재생
        // 그래프는 여전히 옛 샘플레이트로 연결돼 있어서 새 버퍼와 어긋나 조용히 재생이 실패하는
        // 버그가 있었다. 요청받은 sampleRate가 지금 연결된 것과 다르면 매번 다시 연결한다 —
        // 엔진이 돌고 있으면 먼저 멈춘 뒤에(재생 중 그래프를 바꾸면 안 되므로).
        if configuredSampleRate != sampleRate {
            if engine.isRunning {
                engine.stop()
            }
            engine.connect(player, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
            configuredSampleRate = sampleRate
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

        // completionCallbackType을 .dataPlayedBack으로 지정해야 "버퍼를 재생 큐에 넘겼다"가
        // 아니라 "실제로 스피커에서 소리가 다 나갔다" 시점에 콜백이 온다. 콜백 자체는 오디오
        // 스레드에서 오므로, SwiftUI 상태를 건드리려면 메인 큐로 넘겨야 한다.
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async {
                onFinished?()
            }
        }
        player.play()
    }

    func stop() {
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
    }
}
