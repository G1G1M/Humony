import XCTest
@testable import Humony

final class YINPitchDetectorTests: XCTestCase {

    private let sampleRate: Double = 44100.0

    private func sineWave(frequency: Double, sampleCount: Int) -> [Float] {
        (0..<sampleCount).map { i in
            Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    private func cents(detected: Double, expected: Double) -> Double {
        1200.0 * log2(detected / expected)
    }

    func testDetectsA4() throws {
        let samples = sineWave(frequency: 440.0, sampleCount: 2048)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(abs(cents(detected: candidate.frequency, expected: 440.0)), 0, accuracy: 10.0)
    }

    func testDetectsLowMaleVoiceFrequency() throws {
        // 남성 저음역대(약 110Hz, A2)를 커버하는지 확인 — 더 긴 버퍼가 필요하다.
        let samples = sineWave(frequency: 110.0, sampleCount: 4096)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(abs(cents(detected: candidate.frequency, expected: 110.0)), 0, accuracy: 10.0)
    }

    func testDetectsHigherFemaleVoiceFrequency() throws {
        let samples = sineWave(frequency: 880.0, sampleCount: 2048)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(abs(cents(detected: candidate.frequency, expected: 880.0)), 0, accuracy: 10.0)
    }

    func testSilenceReturnsNoCandidate() {
        let samples = [Float](repeating: 0, count: 2048)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)
        XCTAssertTrue(candidates.isEmpty)
    }

    func testConfidenceIsHighForCleanTone() throws {
        let samples = sineWave(frequency: 440.0, sampleCount: 2048)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertGreaterThan(candidate.confidence, 0.9)
    }

    // MARK: - 69절 "길고 안정적으로 잘못된 반음" 진단 — 추측이 아니라 재현 시도

    /// 목소리처럼 배음이 풍부한 신호(PitchShifterTests의 voiceLikeWave와 같은 패턴 재사용) —
    /// 순음(사인파)만으로는 이 앱이 실제로 겪은 문제(반음 아래 오검출)를 재현하지 못할 수
    /// 있어서, 실제 발성에 더 가까운 신호로 진단한다.
    private func voiceLikeWave(frequency: Double, sampleCount: Int, harmonicCount: Int = 8) -> [Float] {
        (0..<sampleCount).map { i in
            var value = 0.0
            for harmonic in 1...harmonicCount {
                value += sin(2.0 * Double.pi * frequency * Double(harmonic) * Double(i) / sampleRate) / Double(harmonic)
            }
            return Float(value)
        }
    }

    /// 실기기에서 보고된 문제 3건(도→시, 레→도#, 솔→파#, 전부 목표음보다 정확히 반음 아래)의
    /// 실제 목표 주파수 — `AudioCapture`가 실제로 쓰는 버퍼 크기(2048샘플)로, 배음이 풍부한
    /// 신호를 넣었을 때도 정확한 음을 잡는지 스윕한다. 실패하면(반음 아래로 검출되면) 재현
    /// 성공 — 코드 수정의 근거가 된다. 통과하면 이 특정 신호 프로파일로는 재현 안 됐다는
    /// 뜻이고, 다른 배음 구성이나 실제 마이크 잡음이 원인일 가능성을 남긴다.
    private func assertVoiceLikeToneIsDetectedAccurately(
        frequency: Double,
        noteName: String,
        bufferSize: Int,
        accuracy: Double = 50.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let samples = voiceLikeWave(frequency: frequency, sampleCount: bufferSize)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)
        let candidate = try XCTUnwrap(candidates.first, "\(noteName)(\(frequency)Hz) 후보 자체가 안 나옴", file: file, line: line)
        let centsOff = cents(detected: candidate.frequency, expected: frequency)
        XCTAssertEqual(
            centsOff, 0, accuracy: accuracy,
            "\(noteName)(\(frequency)Hz, 버퍼 \(bufferSize)) -> \(candidate.frequency)Hz (\(centsOff.rounded())cent 오차)",
            file: file, line: line
        )
    }

    func testLowRegisterVoiceLikeTone_C3_atProductionBufferSize() throws {
        // C3 = MIDI 48. 프로덕션(AudioCapture.bufferSize = 2048)과 동일 조건.
        try assertVoiceLikeToneIsDetectedAccurately(frequency: 130.8128, noteName: "C3", bufferSize: 2048)
    }

    func testLowRegisterVoiceLikeTone_D3_atProductionBufferSize() throws {
        try assertVoiceLikeToneIsDetectedAccurately(frequency: 146.8324, noteName: "D3", bufferSize: 2048)
    }

    func testLowRegisterVoiceLikeTone_G3_atProductionBufferSize() throws {
        try assertVoiceLikeToneIsDetectedAccurately(frequency: 195.9977, noteName: "G3", bufferSize: 2048)
    }

    /// 위 세 테스트가 2048샘플에서 실패한다면(재현 성공), 버퍼를 넉넉히 키웠을 때(상관 윈도우가
    /// 길어짐) 같은 신호가 정확히 잡히는지 — "상관 윈도우 크기가 원인"이라는 가설을 직접
    /// 검증한다. `testDetectsLowMaleVoiceFrequency`가 110Hz에 이미 4096을 쓰던 것과 같은 이유.
    func testLowRegisterVoiceLikeTone_C3_withLargerBuffer() throws {
        try assertVoiceLikeToneIsDetectedAccurately(frequency: 130.8128, noteName: "C3", bufferSize: 8192)
    }

    func testLowRegisterVoiceLikeTone_D3_withLargerBuffer() throws {
        try assertVoiceLikeToneIsDetectedAccurately(frequency: 146.8324, noteName: "D3", bufferSize: 8192)
    }

    func testLowRegisterVoiceLikeTone_G3_withLargerBuffer() throws {
        try assertVoiceLikeToneIsDetectedAccurately(frequency: 195.9977, noteName: "G3", bufferSize: 8192)
    }

    // MARK: - 배음 비율을 바꾼 진단 — 포먼트로 기본음이 약해진 목소리 흉내

    /// 실제 목소리는 성대에서 나온 배음이 성도(포먼트)를 지나며 특정 배음이 기본음보다도 세게
    /// 증폭될 수 있다 — 기본음(1배음) 진폭을 일부러 약하게, 2·3배음을 기본음보다 세게 줘서
    /// "기본 주파수 자체의 자기상관 신호가 약한" 상황을 흉내낸다. 위 8배음(1/n 진폭, 톱니파에
    /// 가까움) 프로파일과 다른 배음 구성으로도 재현을 시도한다.
    private func formantBoostedWave(frequency: Double, sampleCount: Int) -> [Float] {
        // 배음별 진폭 — 1배음(기본음)을 일부러 약하게, 2·3배음을 포먼트처럼 강조.
        let amplitudes: [Double] = [0.25, 1.0, 0.7, 0.35, 0.2, 0.12, 0.08, 0.05]
        return (0..<sampleCount).map { i in
            var value = 0.0
            for (index, amplitude) in amplitudes.enumerated() {
                let harmonic = Double(index + 1)
                value += sin(2.0 * Double.pi * frequency * harmonic * Double(i) / sampleRate) * amplitude
            }
            return Float(value)
        }
    }

    private func assertFormantBoostedToneIsDetectedAccurately(
        frequency: Double,
        noteName: String,
        bufferSize: Int,
        accuracy: Double = 50.0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let samples = formantBoostedWave(frequency: frequency, sampleCount: bufferSize)
        let candidates = YINPitchDetector.detectPitch(samples: samples, sampleRate: sampleRate)
        let candidate = try XCTUnwrap(candidates.first, "\(noteName)(\(frequency)Hz) 후보 자체가 안 나옴", file: file, line: line)
        let centsOff = cents(detected: candidate.frequency, expected: frequency)
        XCTAssertEqual(
            centsOff, 0, accuracy: accuracy,
            "\(noteName)(\(frequency)Hz, 포먼트 강조, 버퍼 \(bufferSize)) -> \(candidate.frequency)Hz (\(centsOff.rounded())cent 오차)",
            file: file, line: line
        )
    }

    func testFormantBoostedTone_C3_atProductionBufferSize() throws {
        try assertFormantBoostedToneIsDetectedAccurately(frequency: 130.8128, noteName: "C3", bufferSize: 2048)
    }

    func testFormantBoostedTone_D3_atProductionBufferSize() throws {
        try assertFormantBoostedToneIsDetectedAccurately(frequency: 146.8324, noteName: "D3", bufferSize: 2048)
    }

    func testFormantBoostedTone_G3_atProductionBufferSize() throws {
        try assertFormantBoostedToneIsDetectedAccurately(frequency: 195.9977, noteName: "G3", bufferSize: 2048)
    }
}
