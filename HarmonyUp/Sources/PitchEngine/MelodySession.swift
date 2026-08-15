import Foundation

/// 마이크에서 매 프레임 들어오는 감지 결과를 누적해서, 지금까지 부른 멜로디를 바탕으로
/// 조성을 판별하고 마지막으로 부른 음에 대한 화음을 제안한다.
/// AudioCapture와 마찬가지로 상태(누적된 pitch-class 길이)를 갖는 I/O 인접 컴포넌트이고,
/// 실제 판단 로직(KeyDetector, ChordGenerator)은 그대로 순수 함수에 위임한다 —
/// 이 클래스는 "프레임 단위 결과를 순수 함수가 원하는 입력 형태로 누적/변환"하는 접착 역할만 한다.
final class MelodySession {

    private var pitchClassDurations = [Double](repeating: 0, count: 12)
    private(set) var lastNote: AudioCapture.DetectionResult?

    /// AudioCapture의 매 프레임 콜백 결과를 그대로 넘기면 된다.
    /// nil(무음/VAD로 걸러진 프레임)은 조성 판단에 영향을 주지 않도록 무시한다.
    func record(_ result: AudioCapture.DetectionResult?) {
        guard let result else { return }
        pitchClassDurations[result.pitchClass] += result.frameDuration
        lastNote = result
    }

    func reset() {
        pitchClassDurations = [Double](repeating: 0, count: 12)
        lastNote = nil
    }

    /// 지금까지 누적된 pitch-class 분포로 판별한 조성. 아직 부른 음이 없으면 nil.
    var detectedKey: KeyDetector.DetectedKey? {
        let notes = pitchClassDurations.enumerated()
            .filter { $0.element > 0 }
            .map { KeyDetector.WeightedNote(pitchClass: $0.offset, duration: $0.element) }
        return KeyDetector.detectKey(notes: notes)
    }

    /// 마지막으로 부른 음 위에 현재 조성 기준 3도/5도 화음을 제안한다.
    /// 조성이 아직 불명확하거나, 마지막 음이 그 조성의 온음계 밖이면 nil.
    var suggestedHarmony: [ChordGenerator.HarmonyNote]? {
        guard let key = detectedKey, let lastNote else { return nil }
        return ChordGenerator.generateHarmony(melodyFrequency: lastNote.frequency, key: key)
    }
}
