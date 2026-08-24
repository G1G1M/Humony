import AVFoundation

/// `[Float]` 버퍼 하나를 트는 최소 구성 재생기 — 어떤 샘플 배열이든 상관없이 재생만 한다.
/// `VoiceClipPlayer`가 쓰던 것과 같은 검증된 패턴(단일 플레이어 노드,
/// `completionCallbackType: .dataPlayedBack`)을 유지한다.
///
/// 145절에 스테레오 재생(`play(left:right:)`)이 추가됐다 — 화음 성부를 좌우로 벌리려면
/// 재생 경로가 2채널이어야 한다. 모노 `play(samples:)`는 그대로 남아 있다(성부 솔로 듣기처럼
/// 한 성부만 정중앙에서 들려주는 쪽은 굳이 스테레오일 이유가 없다).
///
/// 116절에서 화음 재생 인프라(`VoiceClipPlayer` — 다중 트랙/pan/리버브)를 통째로 지우면서
/// 재생 버튼 자체가 없어졌던 걸, 녹음 원본을 다시 들어볼 수 있게 새로 만들었다. 이 타입
/// 자체엔 "녹음"이라는 특정 의미가 없어서(그냥 버퍼 재생기) `PracticeView`가 용도별로 여러
/// 인스턴스를 만들어 재사용해왔다 — 원본 전용 인스턴스는 135절에 "원본" 재생 자체가 UI에서
/// 빠지며 함께 정리됐고, 지금은 `voiceHarmonyPlayer`(내 목소리 화음)와 `soloVoicePlayer`
/// (성부별 솔로 재생)가 이 타입을 쓴다.
final class RecordingPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isAttached = false
    /// 샘플레이트뿐 아니라 채널 수가 바뀔 때도 그래프를 다시 맺어야 한다 — 모노로 연결해둔
    /// 상태에서 스테레오 버퍼를 스케줄하면 포맷 불일치로 즉시 크래시한다(28절에 실기기에서
    /// 실제로 겪은 그 크래시와 같은 원인).
    private var configuredFormat: (sampleRate: Double, channelCount: AVAudioChannelCount)?

    func play(samples: [Float], sampleRate: Double, onFinished: (() -> Void)? = nil) throws {
        guard !samples.isEmpty else { return }
        guard let format = try prepareGraph(sampleRate: sampleRate, channelCount: 1) else { return }

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

    /// 좌우 채널을 따로 받아 스테레오로 재생한다. 두 배열의 길이는 같아야 한다
    /// (`AudioGain.mixToStereo`가 항상 같은 길이로 돌려준다).
    func play(left: [Float], right: [Float], sampleRate: Double, onFinished: (() -> Void)? = nil) throws {
        guard !left.isEmpty, left.count == right.count else { return }
        guard let format = try prepareGraph(sampleRate: sampleRate, channelCount: 2) else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(left.count)
        // standardFormat은 비인터리브(채널마다 별도 배열)라 채널 포인터에 그대로 복사하면 된다.
        left.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            buffer.floatChannelData?[0].update(from: baseAddress, count: left.count)
        }
        right.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            buffer.floatChannelData?[1].update(from: baseAddress, count: right.count)
        }

        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            DispatchQueue.main.async { onFinished?() }
        }
        player.play()
    }

    /// 필요한 포맷으로 오디오 그래프를 준비한다 — 붙이고, 포맷이 달라졌으면 다시 연결하고,
    /// 엔진이 멈춰 있으면 시작한다. 모노/스테레오 재생이 공유한다.
    private func prepareGraph(sampleRate: Double, channelCount: AVAudioChannelCount) throws -> AVAudioFormat? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount) else { return nil }

        if !isAttached {
            engine.attach(player)
            isAttached = true
        }
        // "다시 녹음"처럼 마이크 세션이 재구성되면 실제 하드웨어 샘플레이트가 달라질 수 있다 —
        // 그럴 때(또는 채널 수가 바뀔 때)만 연결을 다시 맺는다(49절에서 겪은 것과 같은 패턴).
        if configuredFormat?.sampleRate != sampleRate || configuredFormat?.channelCount != channelCount {
            if engine.isRunning { engine.stop() }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configuredFormat = (sampleRate, channelCount)
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        return format
    }

    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
    }
}
