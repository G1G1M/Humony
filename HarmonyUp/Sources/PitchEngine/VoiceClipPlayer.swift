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
        // 버퍼 채널 수는 그 버퍼를 재생하는 노드의 "연결 포맷" 채널 수와 정확히 같아야 한다 —
        // 다르면 scheduleBuffer 시점에 크래시가 난다(예전에 겪었던 "채널 수가 다르다" 단언
        // 실패와 같은 종류, docs/CONCEPTS.md 26절). 그래서 원본 데이터는 모노([Float])라도,
        // pan을 쓰려면 연결 자체가 스테레오여야 하니(모노 연결이면 pan이 갈 곳이 없어 무시됨)
        // 버퍼도 스테레오로 만들어서 양쪽 채널에 같은 값을 채운다 — pan은 이 "완전히 가운데인
        // 스테레오" 버퍼의 좌우 상대적 크기를 조절하는 식으로 동작한다(밸런스 컨트롤과 같은 원리).
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }

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

        // 명세서 밖 실기기 피드백("노래가 뒤로 갈수록 화음 박자가 밀린다") 대응 — 예전엔
        // "Swift 메서드 호출 간격은 마이크로초 단위라 사실상 동시"라고 보고 `at: nil`로 스케줄한
        // 뒤 각 플레이어의 `play()`를 순서대로 불렀다. 그런데 `at: nil`은 "그 `play()` 호출이
        // 실제로 처리되는 시점"에 시작하는 것이라, 성부(플레이어) 4개를 위 for문에서 준비하고
        // 아래에서 하나씩 play()를 부르는 사이에 생기는 아주 작은 호출/스케줄링 지연조차 실기기
        // 조건(다른 오디오 처리와 CPU를 다투는 상황)에서는 성부마다 조금씩 다르게 튈 수 있다 —
        // 모든 플레이어가 정확히 같은 하드웨어 시각(host time)에 시작하도록 명시적
        // `AVAudioTime`을 만들어 전부 같은 값으로 스케줄한다. 0.1초 여유를 두는 이유: 이 시각이
        // 지금(now)보다 뒤여야 하고, 아래 스케줄/play() 호출들이 전부 끝난 뒤에 도달해야 의미가
        // 있다 — 너무 타이트하면 이미 지나버린 시각이 되어 오히려 즉시 재생(비동기 오차 재도입)으로
        // 폴백될 수 있다.
        let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.1)
        let startTime = AVAudioTime(hostTime: startHostTime)

        for (index, track) in tracks.enumerated() {
            let player = players[index]
            player.pan = track.pan

            guard let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(track.samples.count)) else {
                onTrackFinished()
                continue
            }
            buffer.frameLength = AVAudioFrameCount(track.samples.count)
            track.samples.withUnsafeBufferPointer { source in
                guard let baseAddress = source.baseAddress else { return }
                // 왼쪽/오른쪽 채널 모두에 같은 값을 채운다("가운데" 스테레오) — pan이 여기서
                // 두 채널의 상대적 크기를 조절해 좌우로 이동시킨다.
                buffer.floatChannelData?[0].update(from: baseAddress, count: track.samples.count)
                buffer.floatChannelData?[1].update(from: baseAddress, count: track.samples.count)
            }

            // completionCallbackType을 .dataPlayedBack으로 지정해야 "버퍼를 재생 큐에 넘겼다"가
            // 아니라 "실제로 스피커에서 소리가 다 나갔다" 시점에 콜백이 온다.
            player.scheduleBuffer(buffer, at: startTime, options: [], completionCallbackType: .dataPlayedBack) { _ in
                onTrackFinished()
            }
        }

        // scheduleBuffer(at:)에 이미 공통 시작 시각을 줬으므로, 여기서 play()는 "그 시각이
        // 오면 재생을 시작할 준비가 됐다"는 뜻일 뿐 — 실제 시작은 4개 플레이어 전부 위에서 준
        // 같은 startTime에 동시에 일어난다.
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
