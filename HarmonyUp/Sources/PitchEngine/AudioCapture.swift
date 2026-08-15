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
    }

    /// nil이면 이 프레임은 무음/저에너지로 판정되어 걸러졌다는 뜻.
    typealias ResultHandler = (DetectionResult?) -> Void

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
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
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
            self?.resultHandler?(result)
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
            frameDuration: Double(samples.count) / sampleRate
        )
    }
}
