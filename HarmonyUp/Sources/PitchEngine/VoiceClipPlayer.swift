import AVFoundation

/// 이미 만들어진 오디오 데이터([Float] 배열, 예: 피치 시프트된 사용자 목소리)를 한 번 재생한다.
/// TonePlayer가 매 샘플을 실시간으로 계산해서 합성하는 반면, 이건 완성된 파형을 그대로 재생만 한다.
final class VoiceClipPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let reverb = AVAudioUnitReverb()
    private var isConfigured = false

    /// - Parameter onFinished: 재생이 실제로 스피커까지 다 끝난 뒤 메인 스레드에서 호출된다.
    ///   호출한 쪽이 "지금 화음이 재생 중이다"라는 상태를 정확히 켜고 끌 수 있게 해준다 —
    ///   이게 없으면(예전 버전) 재생이 언제 끝나는지 알 방법이 없어서, 재생 중에도 마이크가
    ///   계속 켜진 채로 남아있는 문제가 있었다(자세한 이유는 `docs/CONCEPTS.md` 26절 참고).
    func play(samples: [Float], sampleRate: Double, onFinished: (() -> Void)? = nil) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }

        if !isConfigured {
            engine.attach(player)
            engine.attach(reverb)
            // 화음 성부들이 다 같은 공간에서 함께 부르는 듯한 일체감을 주는 공유 리버브
            // (docs/CONCEPTS.md 49절) — 세게 걸면 오히려 성부 구분이 흐려지고 "울림 통에서
            // 녹음한 것" 같아지므로, 은은하게(18%)만 섞어서 WORLD 합성의 미세한 기계음 느낌을
            // 가리는 정도로만 쓴다.
            reverb.loadFactoryPreset(.mediumRoom)
            reverb.wetDryMix = 18
            // format: nil로 연결하면 엔진이 믹서의 기본 포맷(보통 스테레오, 2채널)으로 연결해버려서,
            // 나중에 모노(1채널) 버퍼를 재생하려 하면 "채널 수가 다르다"는 충돌로 앱이 죽는다
            // (_outputFormat.channelCount == buffer.format.channelCount 단언 실패).
            // 버퍼와 정확히 같은 포맷(모노)으로 player→reverb 연결만 명시하고, reverb→믹서는
            // 리버브 유닛이 알아서 결정하는 포맷(보통 스테레오로 퍼짐)을 그대로 받아들인다.
            engine.connect(player, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: nil)
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
