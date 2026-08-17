import AVFoundation

/// AVAudioEngine으로 마이크를 캡처해서, 프레임마다 VAD → YIN → 노트 변환을 거친 결과를 콜백으로 넘겨준다.
/// 다른 PitchEngine 컴포넌트와 달리 이 타입은 순수 함수가 아니라 상태(엔진, 세션)를 갖는 I/O 래퍼다 —
/// 신호처리 핵심 로직은 이미 순수 함수로 분리돼 있으므로, 여기서는 그것들을 마이크 입력에 "연결"만 한다.
final class AudioCapture {

    struct DetectionResult {
        let frequency: Double
        let noteName: String
        let centsOffset: Double
        let confidence: Double
        let pitchClass: Int      // KeyDetector 입력용 (옥타브 무관 음이름)
        let frameDuration: Double  // 이 프레임이 실제로 몇 초 길이였는지 — MelodySession이 조성 판별 가중치로 사용
        let samples: [Float]      // 이 프레임의 원본 파형 — "내 목소리로 화음 만들기"처럼 녹음이 필요한 기능용
        let sampleRate: Double
    }

    /// result가 nil이면 이 프레임은 무음/저에너지로 판정되어 피치 검출에서는 걸러졌다는 뜻 —
    /// 그래도 rawSamples/rawSampleRate는 항상 그 프레임의 원본 파형을 그대로 담아 넘긴다.
    /// (음정 판단·채점용 로직은 `result`만 보고, "내 목소리를 그대로 녹음해서 화음 만들기"처럼
    /// 끊김 없는 원본 오디오가 필요한 기능은 `rawSamples`를 써야 한다 — 자세한 이유는
    /// `docs/CONCEPTS.md` 24절 참고.)
    typealias ResultHandler = (_ result: DetectionResult?, _ rawSamples: [Float], _ rawSampleRate: Double) -> Void

    private let engine = AVAudioEngine()

    // 2048 샘플: 44.1kHz 기준 약 46ms 지연으로 200ms 목표에 여유가 있고,
    // YINPitchDetector가 80Hz(남성 저음)까지 검출하는 데 필요한 tau 탐색 범위(n/2 >= 551)도 충분히 커버한다.
    private let bufferSize: AVAudioFrameCount = 2048

    private var resultHandler: ResultHandler?

    /// 마이크 캡처를 시작한다. 콜백은 항상 메인 큐에서 호출되므로 SwiftUI 상태를 바로 갱신해도 안전하다.
    func start(onResult: @escaping ResultHandler) throws {
        resultHandler = onResult

        let session = AVAudioSession.sharedInstance()
        // .playAndRecord: Phase 3부터 TonePlayer로 목표음을 동시에 재생해야 해서 .record에서 변경.
        // .measurement 모드는 AGC(자동 게인 조절)나 시스템 음성 향상 처리를 최소화해서
        // 원본 파형에 가까운 신호를 얻는다 — 피치 검출 정확도에 중요하다.
        // .defaultToSpeaker: 목표음이 리시버(귀에 대는 작은 스피커)가 아니라 기기 스피커로 나오게 한다.
        // .allowBluetooth/.allowBluetoothA2DP: 이 둘이 빠져 있으면 이 세션이 활성화되는 순간
        // iOS가 블루투스 이어폰을 이 세션에 유효한 입출력 경로로 취급하지 않는다 — 세션 활성화
        // 시점에 블루투스 연결이 끊기거나 강제로 스피커/내장 마이크로 라우팅되는 것처럼 보이는
        // 버그의 원인이었다("이어폰 착용하면 연결이 끊긴다" 실사용 피드백). allowBluetooth는
        // 블루투스로 마이크 입력(HFP)까지 받을 수 있게 하고, allowBluetoothA2DP는 마이크가 안
        // 쓰이는 순간(예: TonePlayer 재생만 할 때) 더 고음질 스테레오 경로(A2DP)를 쓸 수 있게
        // 한다 — 시스템이 상황에 맞게 알아서 고른다.
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.process(buffer: buffer, sampleRate: format.sampleRate)
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // 오디오 탭 콜백은 실시간 오디오 스레드에서 실행되므로, 여기서 결과를 만든 뒤
    // UI/콘솔로 전달하는 부분만 메인 큐로 넘긴다.
    private func process(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))

        let result = computeResult(samples: samples, sampleRate: sampleRate)

        DispatchQueue.main.async { [weak self] in
            self?.resultHandler?(result, samples, sampleRate)
        }
    }

    /// VAD → YIN → 노트 변환을 순서대로 적용하는 순수 계산 부분.
    /// 오디오 스레드에서 직접 실행되지만, 입력을 받아 출력만 반환하는 순수 함수라 별도로 테스트하기도 쉽다.
    private func computeResult(samples: [Float], sampleRate: Double) -> DetectionResult? {
        guard VoiceActivityDetector.isVoiceActive(samples: samples) else { return nil }

        guard let candidate = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate).first else {
            return nil
        }

        guard let note = NoteNameConverter.convert(frequency: candidate.frequency) else { return nil }

        return DetectionResult(
            frequency: candidate.frequency,
            noteName: note.noteName,
            centsOffset: note.centsOffset,
            confidence: candidate.confidence,
            pitchClass: note.pitchClass,
            frameDuration: Double(samples.count) / sampleRate,
            samples: samples,
            sampleRate: sampleRate
        )
    }
}
