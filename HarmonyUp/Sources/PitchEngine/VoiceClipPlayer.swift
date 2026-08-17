import AVFoundation

/// 이미 만들어진 오디오 데이터([Float] 배열, 예: 피치 시프트된 사용자 목소리)를 재생한다.
/// TonePlayer가 매 샘플을 실시간으로 계산해서 합성하는 반면, 이건 완성된 파형을 그대로 재생만 한다.
///
/// 여러 성부를 "동시에, 각자 다른 좌우 위치(pan)로" 재생할 수 있다(docs/CONCEPTS.md 52절) —
/// 리버브(`AVAudioUnitReverb`)는 입력을 하나만 받을 수 있어서, 성부 개수만큼의
/// `AVAudioPlayerNode`를 중간 믹서(`voiceMixer`)로 먼저 합친 뒤 리버브로 보낸다:
/// `player[0..3] → voiceMixer → reverb → mainMixerNode`.
final class VoiceClipPlayer {

    private let engine = AVAudioEngine()
    // 이 앱에서 동시에 재생하는 성부는 최대 4개(리드 멜로디+베이스+3도+5도)라, 그만큼만
    // 미리 만들어 재사용한다 — 호출마다 노드를 새로 attach/detach하면 그래프를 매번 바꿔야
    // 해서 더 위험하다.
    private let players: [AVAudioPlayerNode] = (0..<4).map { _ in AVAudioPlayerNode() }
    private let voiceMixer = AVAudioMixerNode()
    private let reverb = AVAudioUnitReverb()
    private var isAttached = false
    // 재생 그래프가 지금 어떤 샘플레이트로 연결돼 있는지 — "다시 녹음"처럼 마이크 세션이
    // 재구성될 때마다 실제 하드웨어 샘플레이트가 달라질 수 있어서, 이 값이 바뀌면 연결을
    // 다시 맺어야 한다(docs/CONCEPTS.md 49절에서 겪은 버그, 여기서도 동일하게 적용).
    private var configuredSampleRate: Double?

    /// - Parameter onFinished: 재생이 실제로 스피커까지 다 끝난 뒤(재생한 트랙 전부) 메인
    ///   스레드에서 한 번 호출된다.
    func play(samples: [Float], sampleRate: Double, onFinished: (() -> Void)? = nil) throws {
        try playTracks([(samples: samples, pan: 0.0)], sampleRate: sampleRate, onFinished: onFinished)
    }

    /// 여러 트랙을 동시에, 각자 지정한 pan(-1~1)으로 재생한다. 트랙 길이가 서로 달라도(피치
    /// 시프트 특성상 흔함) 각자 자기 길이만큼만 재생되고 끝난다 — 예전(`AudioGain.mixAndNormalize`)
    /// 처럼 Swift 배열 단계에서 미리 합칠 때만 필요했던 "가장 짧은 길이에 맞추기"가 더는
    /// 필요 없다(하드웨어 믹서가 알아서 겹쳐 재생하므로).
    /// - Parameter onFinished: 트랙 전부가 재생을 마친 뒤(가장 늦게 끝나는 트랙 기준) 메인
    ///   스레드에서 한 번만 호출된다.
    func playTracks(_ tracks: [(samples: [Float], pan: Float)], sampleRate: Double, onFinished: (() -> Void)? = nil) throws {
        guard !tracks.isEmpty, tracks.count <= players.count else { return }
        // 버퍼 자체는 모노(실제 녹음/합성 데이터 그대로)지만, 연결 포맷은 스테레오여야
        // AVAudioPlayerNode의 pan이 실제로 좌우에 반영된다 — 모노 버퍼를 스테레오 연결에
        // 흘려보내는 건 pan을 쓰기 위한 정석적인 방법이다.
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

        if !isAttached {
            for player in players {
                engine.attach(player)
            }
            engine.attach(voiceMixer)
            engine.attach(reverb)
            // 화음 성부들이 다 같은 공간에서 함께 부르는 듯한 일체감을 주는 공유 리버브
            // (docs/CONCEPTS.md 49절) — 세게 걸면 오히려 성부 구분이 흐려지므로 은은하게(18%)만.
            reverb.loadFactoryPreset(.mediumRoom)
            reverb.wetDryMix = 18
            isAttached = true
        }

        if configuredSampleRate != sampleRate {
            if engine.isRunning {
                engine.stop()
            }
            for player in players {
                engine.connect(player, to: voiceMixer, format: stereoFormat)
            }
            engine.connect(voiceMixer, to: reverb, format: stereoFormat)
            engine.connect(reverb, to: engine.mainMixerNode, format: stereoFormat)
            configuredSampleRate = sampleRate
        }

        // 트랙을 여러 개 동시에 재생하면 하드웨어 믹서에서 그대로 더해져서 트랙 수만큼
        // 커질 수 있다 — "동시에 울리는 신호를 합칠 때 진폭이 아니라 에너지가 더해진다"는
        // 가정 하에 흔히 쓰는 등에너지(equal-power) 보정(1/√N)으로 대략적인 헤드룸을 둔다.
        engine.mainMixerNode.outputVolume = Float(1.0 / Double(tracks.count).squareRoot())

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        // 트랙 전부가 끝나야 onFinished를 딱 한 번만 부른다.
        var remaining = tracks.count
        let onTrackFinished: () -> Void = {
            DispatchQueue.main.async {
                remaining -= 1
                if remaining == 0 {
                    onFinished?()
                }
            }
        }

        for (index, track) in tracks.enumerated() {
            let player = players[index]
            player.pan = track.pan

            guard let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(track.samples.count)) else {
                onTrackFinished()
                continue
            }
            buffer.frameLength = AVAudioFrameCount(track.samples.count)
            track.samples.withUnsafeBufferPointer { source in
                guard let baseAddress = source.baseAddress else { return }
                buffer.floatChannelData?[0].update(from: baseAddress, count: track.samples.count)
            }

            // completionCallbackType을 .dataPlayedBack으로 지정해야 "버퍼를 재생 큐에 넘겼다"가
            // 아니라 "실제로 스피커에서 소리가 다 나갔다" 시점에 콜백이 온다.
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
                onTrackFinished()
            }
        }

        // 여러 노드를 정확히 같은 샘플에서 시작시키는 건(AVAudioTime 기반) 이 용도(4개 성부를
        // 몇 ms 오차 안에 함께 재생)엔 과한 정교함이라, 단순하게 바로 이어서 play()를 부른다 —
        // Swift 메서드 호출 간격은 마이크로초 단위라 사람 귀로는 사실상 동시로 들린다.
        for index in 0..<tracks.count {
            players[index].play()
        }
    }

    func stop() {
        for player in players {
            player.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
    }
}
