import Foundation

/// `render.js`의 `window.renderScore(data)`에 넘길 악보 페이로드를 `MelodyStep` 배열에서
/// 조립하는 순수 로직. 원래 `VexFlowScoreView`의 private 메서드였는데, 136절에 멜로디 1성부에서
/// 4성부(멜로디/5도/3도/베이스)로 늘리면서 밖으로 뽑았다 — CLAUDE.md의 "조합 로직을 View의
/// 메서드 안에 두지 말 것"(화음 오디오 파이프라인이 `PracticeView` 확장 메서드로 있던 동안
/// 길이 어긋남 버그를 유닛테스트 없이 실기기 청취로만 발견했던 그 규칙) 때문이다. 특히
/// 다성부에서는 **모든 성부의 음 개수가 같고 마디 구성을 공유해야 마디선이 세로로 맞는다**는
/// 불변식이 생기는데, 그건 눈으로 악보를 봐서 확인하기보다 테스트로 고정하는 게 확실하다.
enum VexFlowScorePayload {

    struct Payload: Encodable, Equatable {
        struct Voice: Encodable, Equatable {
            let clef: String
            let notes: [Note]
        }
        struct Note: Encodable, Equatable {
            /// nil이면 쉼표 — 그 성부가 이 스텝엔 음이 없다는 뜻(화음을 못 정의한 스텝 등).
            let key: String?
            let sharp: Bool
            let duration: String

            // 합성된 기본 인코딩은 nil optional의 **키 자체를 생략**한다(encodeIfPresent 사용).
            // render.js는 `!n.key`로 쉼표를 판정하니 undefined여도 우연히 동작하지만, 그쪽
            // 문서가 명시하는 계약은 "key가 null이면 쉼표"다 — 문서와 실제 전송 형태를
            // 어긋나게 두지 않도록 null을 명시적으로 내보낸다(Optional은 그 자체가 Encodable이라
            // 아래처럼 그냥 encode하면 encodeNil로 내려가 JSON null이 된다).
            enum CodingKeys: String, CodingKey { case key, sharp, duration }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(key, forKey: .key)
                try container.encode(sharp, forKey: .sharp)
                try container.encode(duration, forKey: .duration)
            }
        }
        let voices: [Voice]
        let measureBreaks: [Int]
    }

    static let empty = Payload(voices: [], measureBreaks: [])

    /// 악보에 그릴 성부와, 각 성부의 음을 `MelodyStep`에서 꺼내는 방법 — 배열 순서가 그대로
    /// 위에서 아래로 그려지는 오선 순서다.
    ///
    /// **왜 멜로디 → 5도 → 3도 → 베이스인가**: 오선보는 높은 성부를 위에 놓는 게 관례이고,
    /// `ChordGenerator`가 그 순서를 수학적으로 보장한다(`ChordGenerator.Interval.displayOrder`
    /// 문서 참고). 그 순서는 이제 앱 전체가 공유하므로 여기서 따로 적지 않고 그대로 가져온다 —
    /// 예전엔 조작부(`soloVoiceOptions`)가 정반대 순서를 쓰고 있었다.
    static let voiceOrder: [(label: String, interval: ChordGenerator.Interval?)] =
        [(label: "멜로디", interval: nil)]
        + ChordGenerator.Interval.displayOrder.map { (label: $0.koreanLabel, interval: $0) }

    /// 스텝 하나에서 특정 성부의 MIDI 노트를 꺼낸다. `interval`이 nil이면 멜로디 자신.
    /// 화음이 아예 없는 스텝(`harmony == nil` — 조성 판별 실패 등)은 nil을 돌려주고,
    /// 호출부가 쉼표로 그린다.
    static func midiNote(in step: MelodyStep, interval: ChordGenerator.Interval?) -> Int? {
        guard let interval else { return step.midiNote }
        return step.harmony?.first { $0.interval == interval }?.midiNote
    }

    /// 한 성부가 **이벤트 순서대로** 갖는 음. 쉼표 자리와, 그 성부에만 음이 없는 자리는 nil이다.
    /// 모든 성부가 같은 길이의 배열을 갖는 것이 마디선이 세로로 맞는 전제다.
    static func midiNotes(steps: [MelodyStep], events: [ScoreTimeline.Event], interval: ChordGenerator.Interval?) -> [Int?] {
        events.map { event in
            guard case .note(let stepIndex, _, _) = event else { return nil }  // 쉼표
            return midiNote(in: steps[stepIndex], interval: interval)
        }
    }

    /// **실제로 악보에 그려지는 성부**를 위에서 아래 순서로 — 배열 인덱스가 곧 `render.js`의 행
    /// 인덱스다.
    ///
    /// 음이 하나도 없는 성부(조성을 못 잡아 화음이 전혀 안 붙은 녹음 등)는 쉼표만 가득한 빈
    /// 오선을 그리는 대신 **행 자체가 빠진다** — 그래서 `voiceOrder`의 인덱스를 그대로 행
    /// 인덱스로 쓰면 안 된다. 그 판정이 `build`와 여기 두 군데로 갈라지면 조용히 어긋나므로
    /// (칠할 행을 계산하는 쪽이 다른 행을 가리키게 된다) `build`도 이 함수를 통해서만 성부를 정한다.
    static func drawnVoices(steps: [MelodyStep], events: [ScoreTimeline.Event]) -> [(label: String, interval: ChordGenerator.Interval?)] {
        guard !events.isEmpty else { return [] }
        return voiceOrder.filter { voice in
            midiNotes(steps: steps, events: events, interval: voice.interval).contains { $0 != nil }
        }
    }

    static func drawnVoices(steps: [MelodyStep]) -> [(label: String, interval: ChordGenerator.Interval?)] {
        drawnVoices(steps: steps, events: ScoreTimeline.events(from: steps))
    }

    static func build(steps: [MelodyStep]) -> Payload {
        // 149절 — 음표 길이를 "부른 시간"이 아니라 **다음 음까지의 간격**으로 잡고, 남는 무음은
        // 쉼표로 뗀다(`ScoreTimeline`). 박을 간격에서 찾으면서(139절) 길이는 발성 시간을 쓰던
        // 어긋남을 없앤다. onsetTime이 없는 스텝을 건너뛰는 규칙도 그 안에 들어 있다.
        let events = ScoreTimeline.events(from: steps)
        guard !events.isEmpty else { return empty }

        // 리듬(음표 길이)과 마디 구성은 타임라인 하나에서만 계산해서 전 성부가 공유한다 —
        // 화음은 멜로디와 같은 순간에 같은 길이로 울리므로(`VoiceHarmonyTrackBuilder`가
        // melodySteps의 onset/duration을 그대로 쓴다) 성부별로 따로 계산할 게 없고, 무엇보다
        // 모든 성부의 음 개수와 마디 구성이 같아야 render.js에서 마디선이 세로로 맞는다.
        //
        // 박 추정에 넘기는 건 **음표의 시작 시각만**이다(136절) — 쉼표는 onset이 아니라서
        // 넣으면 간격 통계가 오염된다. `RhythmQuantizer`는 onsetTimes를 박 추정에만 쓰고
        // 길이 분류는 durations로 따로 하므로 두 배열의 길이가 달라도 된다.
        let noteStarts: [Double] = events.compactMap { event in
            guard case .note(_, let start, _) = event else { return nil }
            return start
        }
        let quantized = RhythmQuantizer.quantize(
            durations: events.map(\.duration),
            onsetTimes: noteStarts
        )
        let measureBreaks = RhythmQuantizer.measureBreaks(notes: quantized)

        let voices: [Payload.Voice] = drawnVoices(steps: steps, events: events).map { voice in
            let midiNotes = Self.midiNotes(steps: steps, events: events, interval: voice.interval)

            let notes = zip(midiNotes, quantized).map { midiNote, quantizedNote -> Payload.Note in
                guard let midiNote else {
                    // 진짜 쉼표든, 그 성부에만 음이 없는 자리든 똑같이 쉼표로 채운다 — 성부마다
                    // 음 개수가 같아야 마디선이 세로로 맞는다.
                    return Payload.Note(key: nil, sharp: false, duration: quantizedNote.vexFlowDuration)
                }
                let (key, sharp) = vexFlowKey(forMIDINote: midiNote)
                return Payload.Note(key: key, sharp: sharp, duration: quantizedNote.vexFlowDuration)
            }
            // 실제 음역에 맞는 음자리표를 성부마다 따로 고른다 — 항상 높은음자리표로 고정하면
            // 베이스처럼 낮은 성부에서 덧줄이 여러 개 필요해 오선 한참 아래로 내려가 보인다.
            return Payload.Voice(clef: clef(forMIDINotes: midiNotes.compactMap { $0 }), notes: notes)
        }

        return Payload(voices: voices, measureBreaks: measureBreaks)
    }

    /// `render.js`에 그대로 넘길 JSON 문자열. 인코딩이 실패할 일은 사실상 없지만(전부 값 타입),
    /// 실패하면 빈 악보를 그리게 해서 화면이 깨지지 않게 한다.
    static func json(steps: [MelodyStep]) -> String {
        let payload = build(steps: steps)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return "{\"voices\":[],\"measureBreaks\":[]}"
        }
        return json
    }

    // MARK: - MIDI -> VexFlow 표기

    // MIDI 노트 -> VexFlow 키 문자열("c#/4" 형식) + 샵 필요 여부. 반음(피치클래스)이 아니라
    // 다이어토닉 레터(흰건반, 옥타브당 7개) 단위로 표기하는 오선보 규칙을 그대로 따른다 —
    // 흰건반 사이 음은 바로 아래 자연음과 같은 레터를 쓰고 샵만 붙인다. 이 v1은 플랫 없이
    // 항상 샵으로만 표기한다(56절에서 이미 채택한 것과 같은 단순화).
    static let naturalLetters: [(pitchClass: Int, letter: String)] = [
        (0, "c"), (2, "d"), (4, "e"), (5, "f"), (7, "g"), (9, "a"), (11, "b")
    ]

    static func vexFlowKey(forMIDINote midiNote: Int) -> (key: String, sharp: Bool) {
        let octave = midiNote / 12 - 1 // MIDI 60 = C4 관례(이 프로젝트 전반과 동일)
        let pitchClass = midiNote.mod(12)
        if let match = naturalLetters.first(where: { $0.pitchClass == pitchClass }) {
            return ("\(match.letter)/\(octave)", false)
        }
        let below = naturalLetters.last(where: { $0.pitchClass < pitchClass })!
        return ("\(below.letter)/\(octave)", true)
    }

    /// 그 성부의 실제 음역(이번 녹음에서 나온 MIDI 노트들)을 보고 어느 음자리표가 자연스러운지
    /// 고른다. MIDI 60(미들 C)을 그대로 기준 삼지 않고 조금 낮춘 이유: 높은음자리표는 미들
    /// C보다 아래에서도 어느 정도(첫째 줄=E4=MIDI64까지) 덧줄 없이 표현되니, 평균이 그보다
    /// 살짝만 낮아도 굳이 낮은음자리표로 넘길 필요는 없다 — 대신 낮은음자리표 가운데줄
    /// (D3=MIDI50)에 걸치는 지점을 기준으로 삼는다.
    static func clef(forMIDINotes midiNotes: [Int]) -> String {
        guard !midiNotes.isEmpty else { return "treble" }
        let average = midiNotes.reduce(0, +) / midiNotes.count
        return average < 57 ? "bass" : "treble" // 57 = A3, 낮은음자리표 셋째줄 바로 위
    }
}
