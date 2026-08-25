import Foundation

/// 화음 성부 한 소절을 따라 부른 녹음을 목표 성부와 맞춰 채점하는 순수 함수(136절).
///
/// **왜 프레임 단위 실시간 채점이 아닌가**: 예전 채점(`PitchScorer` + `PracticeView` 실시간
/// 경로)은 "목표음 하나를 붙잡고 지속 발성"하는 구조였다 — 이 앱의 목표는 한 음을 배우는 게
/// 아니라 **화음 한 소절을 부르는 것**이라 흐름 자체를 바꿨다. 재생(먼저 들어보기)과 녹음
/// (따라 부르기)을 시간상 분리해서, 스피커 소리가 마이크로 되돌아오는 피드백 루프 문제를
/// 애초에 만들지 않는다(`AudioCapture` 쪽 가드와 오디오 세션 설정을 손대지 않아도 된다).
///
/// **왜 시간 정보를 안 받는가**: 입력이 "목표 음높이 시퀀스"와 "부른 음높이 시퀀스" 두 개뿐이다.
/// 무반주로 부르는 앱이라 템포를 강제할 수 없고, 강제할 이유도 없다 — 채점 대상은 음정이다.
/// 시간을 아예 입력에서 빼는 것이 "템포가 달라도 같은 점수"를 코드 구조로 보장하는 방법이다.
enum HarmonyPracticeScorer {

    /// 목표음 하나에 대한 채점 결과.
    struct StepResult: Equatable {
        let targetMIDINote: Int
        /// 이 목표음에 짝지어진, 실제로 부른 음. nil이면 그 음을 안 불렀다(누락).
        let sungMIDINote: Int?
        /// 목표 대비 편차(cent). 양수 = 목표보다 높게 불렀다. 누락이면 nil.
        let centsOffset: Double?
        let isOnPitch: Bool
    }

    struct Result: Equatable {
        let steps: [StepResult]
        /// 허용 오차 안에 든 목표음의 비율(0~1). 누락도 분모에 포함된다 — 안 부른 음은
        /// 정확히 부른 게 아니다.
        let onPitchRatio: Double
        /// 짝지어진 음들의 평균 편차 크기(cent, 부호 무시) — "얼마나 벗어났나".
        let averageAbsCentsOffset: Double
        /// 부호를 살린 평균 편차 — "전반적으로 높게/낮게 부르는 편"인지 알려준다.
        /// 절대값 평균만으로는 방향이 안 보인다.
        let averageSignedCentsOffset: Double
        /// 짝을 못 찾은 목표음 개수(안 부른 음).
        let missedCount: Int
        /// 목표에 없는데 부른 음 개수.
        let extraCount: Int
    }

    /// 짝을 짓지 않고 건너뛸 때(목표음 누락 또는 군더더기 음) 매기는 비용(cent 단위).
    ///
    /// **왜 600인가**: 누락+추가 한 쌍의 비용이 1200cent(정확히 한 옥타브)가 되도록 잡았다.
    /// 그보다 가까운 음을 불렀다면 "틀리게 불렀다"로 보고 짝을 지어 얼마나 벗어났는지 보여주는
    /// 편이 진단에 유용하고(예: 전체를 반음 높게 부른 경우 — 짝을 지어야 "100cent 높음"이라는
    /// 사실이 드러난다), 한 옥타브를 넘게 동떨어진 음이라면 아예 다른 음을 부른 것으로 보는 게
    /// 맞다("1900cent 벗어났다"는 숫자는 아무 도움이 안 된다).
    static let gapPenaltyCents = 600.0

    /// - Parameters:
    ///   - targetFrequencies: 목표 성부(예: 3도)의 음을 소절 순서대로. 0 이하 값은 걸러진다.
    ///   - sungFrequencies: 사용자가 실제로 부른 음을 순서대로(`MelodySegmenter`가 잘라낸 것).
    /// - Returns: 목표음이 하나도 없으면 nil(채점할 게 없다). 부른 음이 없는 경우는 nil이 아니라
    ///   "전부 누락"인 결과를 돌려준다 — 저장할 가치가 있는 결과다.
    static func score(targetFrequencies: [Double], sungFrequencies: [Double]) -> Result? {
        let targets = targetFrequencies.filter { $0 > 0 }
        guard !targets.isEmpty else { return nil }
        let sung = sungFrequencies.filter { $0 > 0 }

        // 정렬은 "선형 거리 공간"에서 해야 한다 — 주파수 그대로면 높은 음의 Hz 간격이 커서
        // 비용이 왜곡된다. cent 좌표로 옮기면 두 좌표의 차이가 곧 cent 편차가 된다.
        let pairs = MelodyAligner.align(
            targets: targets.map(centsCoordinate),
            sung: sung.map(centsCoordinate),
            gapPenalty: gapPenaltyCents
        )

        var steps: [StepResult] = []
        var extraCount = 0
        var absOffsets: [Double] = []
        var signedOffsets: [Double] = []

        for pair in pairs {
            switch (pair.targetIndex, pair.sungIndex) {
            case let (targetIndex?, sungIndex?):
                let cents = centsBetween(target: targets[targetIndex], sung: sung[sungIndex])
                absOffsets.append(abs(cents))
                signedOffsets.append(cents)
                steps.append(StepResult(
                    targetMIDINote: roundedMIDINote(targets[targetIndex]),
                    sungMIDINote: roundedMIDINote(sung[sungIndex]),
                    centsOffset: cents,
                    isOnPitch: abs(cents) <= PitchScorer.onPitchToleranceCents
                ))
            case let (targetIndex?, nil):
                steps.append(StepResult(
                    targetMIDINote: roundedMIDINote(targets[targetIndex]),
                    sungMIDINote: nil,
                    centsOffset: nil,
                    isOnPitch: false
                ))
            case (nil, _?):
                extraCount += 1
            case (nil, nil):
                continue // align이 만들지 않는 조합
            }
        }

        let onPitchCount = steps.filter(\.isOnPitch).count
        return Result(
            steps: steps,
            onPitchRatio: Double(onPitchCount) / Double(steps.count),
            averageAbsCentsOffset: average(absOffsets),
            averageSignedCentsOffset: average(signedOffsets),
            missedCount: steps.filter { $0.sungMIDINote == nil }.count,
            extraCount: extraCount
        )
    }

    // MARK: - 보조

    /// 주파수를 cent 좌표로. 두 좌표의 차이가 그대로 cent 편차가 되므로 정렬 비용에 바로 쓸 수 있다.
    private static func centsCoordinate(_ frequency: Double) -> Double {
        1200.0 * log2(frequency)
    }

    /// 목표 대비 편차(cent). `PitchScorer.score`와 같은 공식이지만, 이쪽은 허용 오차 판정 전의
    /// 원시 편차만 필요하고 옵셔널을 만들지 않아서 결과 조립에 쓰기 편하다.
    private static func centsBetween(target: Double, sung: Double) -> Double {
        1200.0 * log2(sung / target)
    }

    private static func roundedMIDINote(_ frequency: Double) -> Int {
        Int(NoteNameConverter.exactMIDINote(forFrequency: frequency).rounded())
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - 녹음에서 채점까지

/// `PracticeView`가 부르는 진입점 — 목표 시퀀스를 꺼내고, 녹음 버퍼를 음표로 잘라 채점한다.
/// 뷰가 직접 `MelodySegmenter`/`AudioGain`을 조립하지 않도록 여기 모아뒀다(CLAUDE.md: 조합
/// 로직을 View의 메서드 안에 두지 말 것 — 그래야 유닛테스트로 고정할 수 있다).
extension HarmonyPracticeScorer {

    /// 목표 성부(예: 3도)의 음을 소절 순서대로 뽑는다. 화음이 없는 스텝(온음계 밖 등)은
    /// 목표에서 빠진다 — 부를 음이 없는 자리를 "누락"으로 세면 부당하게 감점된다.
    static func targetFrequencies(from steps: [MelodyStep], interval: ChordGenerator.Interval) -> [Double] {
        steps.compactMap { step in
            step.harmony?.first { $0.interval == interval }?.frequency
        }
    }

    /// 따라 부른 녹음 전체를 채점한다.
    ///
    /// 멜로디 캡처(`RecordingAnalyzer.analyze`)와 달리 조성 판별/화음 생성은 하지 않는다 —
    /// 채점에 필요한 건 "부른 음이 무엇이었나"뿐이라 `MelodySegmenter`까지만 쓴다. 게인 정규화를
    /// 먼저 거치는 것도 같은 경로와 같은 이유다(기기별 마이크 원본 게인 차이가 VAD/YIN 판정을
    /// 좌우하는 걸 실측으로 확인한 63절 이후의 관례).
    static func score(recordingSamples: [Float], sampleRate: Double, targetFrequencies targets: [Double]) -> Result? {
        let normalized = AudioGain.normalizeLoudness(recordingSamples)
        let sungNotes = MelodySegmenter.segment(samples: normalized, sampleRate: sampleRate)
        let sungFrequencies = sungNotes.map { NoteNameConverter.frequency(forMIDINote: $0.midiNote) }
        return score(targetFrequencies: targets, sungFrequencies: sungFrequencies)
    }
}
