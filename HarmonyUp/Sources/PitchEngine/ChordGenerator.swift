import Foundation

/// 판별된 조성(KeyDetector.DetectedKey)을 기준으로, 멜로디 음 하나에 대해 3성부
/// (베이스/이너보이스1(3도)/이너보이스2(5도))를 생성한다 — 아카펠라 4인 편성(리드 멜로디 +
/// 이 3성부)을 흉내낸다.
///
/// "지금 재생 중인 반주 코드"를 별도로 입력받지 않는다 — 이 앱은 반주 없이 목소리 하나만
/// 녹음/분석하는 구조라 코드 데이터가 저절로 생기는 소스가 없고, "멜로디를 녹음하면 나머지
/// 화성이 다 자동으로 나와야 한다"는 요구사항 때문이다. 대신 **멜로디 음 자신을 그 순간
/// 화음의 근음(root)으로 본다** — 멜로디 음의 스케일 디그리 위에 다이아토닉 3도/5도를 쌓아
/// 트라이어드를 만들고, 그 근음(멜로디와 같은 음이름)을 한 옥타브 내려 베이스로 삼는다.
enum ChordGenerator {

    enum Interval: Hashable, CaseIterable {
        case bass
        case third
        case fifth

        // 온음계에서 "3도 위", "5도 위"는 반음 몇 개가 아니라 음계상 몇 칸(scale degree) 위인지로 정의한다 —
        // 그래야 장3도/단3도가 조성에 따라 자동으로 올바르게 섞여 나온다(예: C장조의 3도는 C-E, D장조의 3도는 D-F#).
        // 베이스는 멜로디와 같은 음이름(근음)이므로 0칸 — 옥타브만 달라진다.
        var scaleDegreeStep: Int {
            switch self {
            case .bass: return 0
            case .third: return 2
            case .fifth: return 4
            }
        }

        /// 화면에 보여줄 짧은 한글 라벨 — 여러 화면(멜로디 스텝 목록, 재생 버튼, 채점 패널)에서
        /// 같은 표기를 반복하지 않도록 한 곳에 모았다.
        var koreanLabel: String {
            switch self {
            case .bass: return "베이스"
            case .third: return "3도"
            case .fifth: return "5도"
            }
        }
    }

    struct HarmonyNote {
        let interval: Interval
        let midiNote: Int
        let frequency: Double
        let pitchClass: Int
    }

    // 온음계를 이루는 반음 간격. 장조(Ionian)와 자연 단조(Aeolian) — 두 경우 모두
    // 으뜸음에서부터 7개 음이 어떤 반음 간격으로 놓이는지를 나타낸다.
    private static let majorScaleIntervals = [0, 2, 4, 5, 7, 9, 11]
    private static let minorScaleIntervals = [0, 2, 3, 5, 7, 8, 10]

    /// - Parameters:
    ///   - melodyFrequency: 사용자가 부른 멜로디 음(Hz) — 그 순간 화음의 근음으로 취급한다.
    ///   - key: KeyDetector가 판별한 조성
    /// - Returns: `[베이스, 이너보이스1(3도), 이너보이스2(5도)]`. 멜로디 음이 판별된 조성의
    ///   온음계에 속하지 않으면(예: 반음계 경과음, 임시표) 온음계 화성을 정의할 수 없으므로
    ///   `nil`을 반환한다 — 새로운 반음계 화성 규칙을 만들지 않고, 기존과 같은 "온음계 밖 음은
    ///   화음 없음" 동작을 그대로 유지한다.
    static func generateHarmony(melodyFrequency: Double, key: KeyDetector.DetectedKey) -> [HarmonyNote]? {
        guard melodyFrequency > 0 else { return nil }

        let melodyMIDINote = Int(NoteNameConverter.exactMIDINote(forFrequency: melodyFrequency).rounded())
        let melodyPitchClass = melodyMIDINote.mod(12)

        let scale = diatonicScale(tonic: key.tonicPitchClass, mode: key.mode)
        guard let melodyDegree = scale.firstIndex(of: melodyPitchClass) else { return nil }

        let bass = bassNote(melodyMIDINote: melodyMIDINote)
        let third = innerVoiceNote(interval: .third, melodyDegree: melodyDegree, scale: scale, bassMIDINote: bass.midiNote, melodyMIDINote: melodyMIDINote)
        let fifth = innerVoiceNote(interval: .fifth, melodyDegree: melodyDegree, scale: scale, bassMIDINote: bass.midiNote, melodyMIDINote: melodyMIDINote)

        return [bass, third, fifth]
    }

    private static func diatonicScale(tonic: Int, mode: KeyDetector.Mode) -> [Int] {
        let intervals = mode == .major ? majorScaleIntervals : minorScaleIntervals
        return intervals.map { (tonic + $0).mod(12) }
    }

    /// 베이스 = 멜로디와 같은 음이름(근음)을 1옥타브 아래로. "1~2옥타브 아래의 안정적인
    /// 음역대"라는 요구사항 중 가장 단순하고 결정적인 규칙(항상 정확히 1옥타브)을 택했다 —
    /// 멜로디 음역에 따라 옥타브 폭을 동적으로 바꾸는 건 더 정교하지만, 그만큼 "왜 이 음에서는
    /// 2옥타브 내려가고 저 음에서는 1옥타브만 내려가는지"를 예측하기 어려워진다.
    private static func bassNote(melodyMIDINote: Int) -> HarmonyNote {
        let midiNote = melodyMIDINote - 12
        return HarmonyNote(
            interval: .bass,
            midiNote: midiNote,
            frequency: NoteNameConverter.frequency(forMIDINote: midiNote),
            pitchClass: midiNote.mod(12)
        )
    }

    /// 3도/5도 이너보이스 — 베이스와 멜로디 "사이"에 배치한다(예전엔 멜로디 "위"에 쌓았다).
    ///
    /// 성부 교차가 나지 않는 이유(수학적으로 항상 성립): 온음계에서 근음 기준 3도는 항상
    /// 3~4반음, 5도는 항상 6~8반음 위다(장/단조 자연음계 어디서 시작해도 이 범위를 벗어나지
    /// 않는다) — 즉 "3도 거리 < 5도 거리 < 12(한 옥타브, 베이스-멜로디 간격)"가 항상 성립해서,
    /// 베이스 < 3도 < 5도 < 멜로디 순서가 별도의 재정렬 없이 자연히 유지된다.
    private static func innerVoiceNote(
        interval: Interval,
        melodyDegree: Int,
        scale: [Int],
        bassMIDINote: Int,
        melodyMIDINote: Int
    ) -> HarmonyNote {
        let targetDegree = (melodyDegree + interval.scaleDegreeStep) % 7
        let targetPitchClass = scale[targetDegree]

        // 베이스와 같은 옥타브 밴드에서 목표 음이름의 위치를 먼저 찾는다.
        let bassOctaveBase = bassMIDINote - bassMIDINote.mod(12)
        var targetMIDINote = bassOctaveBase + targetPitchClass

        // 안전장치(성부 침해/교차 방지): 계산 결과가 베이스보다 낮거나 같으면 한 옥타브 올리고,
        // 혹시라도 멜로디보다 높거나 같으면 한 옥타브 내린다. 위 계산 근거상 두 조건이 동시에
        // 필요한 경우는 없지만, 방어적으로 둘 다 확인해서 어떤 조성/디그리 조합에서도
        // 베이스 < 이 음 < 멜로디가 깨지지 않게 한다.
        if targetMIDINote <= bassMIDINote {
            targetMIDINote += 12
        }
        if targetMIDINote >= melodyMIDINote {
            targetMIDINote -= 12
        }

        return HarmonyNote(
            interval: interval,
            midiNote: targetMIDINote,
            frequency: NoteNameConverter.frequency(forMIDINote: targetMIDINote),
            pitchClass: targetPitchClass
        )
    }
}
