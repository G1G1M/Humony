import Foundation

/// 음표 머리의 세로 위치를 음높이로 옮긴다 (156절).
///
/// 오선에서 **줄과 칸이 번갈아 온음계 한 계단**이다(줄 → 칸 → 줄 = 두 계단 = 줄 간격 하나).
/// 그래서 필요한 건 줄 간격 하나뿐이고, 사진의 해상도나 촬영 거리는 알 필요가 없다.
///
/// **온음계 계단으로 세는 게 핵심이다.** 악보의 세로 위치는 반음이 아니라 음이름(C D E F G A B)
/// 단위로 균등하다 — E와 F는 붙어 있고(반음) B와 C도 그렇지만, 오선에서는 다른 자리와 똑같이
/// 한 칸이다. 반음 계산은 음이름을 정한 뒤 조표에서 온다.
enum StaffPitchMapper {

    enum Clef {
        case treble
        case bass
    }

    /// 오선 맨 아래 줄을 0으로 하고 위로 갈수록 커지는 온음계 계단.
    ///
    /// 검출된 머리 좌표는 픽셀 단위로 조금씩 어긋나므로 가장 가까운 계단으로 붙인다 —
    /// 반 칸(= 계단 하나)의 절반 이상 어긋나야 옆 계단으로 넘어간다.
    static func diatonicStep(y: Double, staff: StaffDetector.Staff) -> Int {
        guard let bottomLineY = staff.lineYs.last, staff.spacing > 0 else { return 0 }
        return Int(((bottomLineY - y) / (staff.spacing / 2)).rounded())
    }

    /// 계단 + 음자리표 + 조표 → MIDI 노트.
    static func midiNote(diatonicStep: Int, clef: Clef, fifths: Int) -> Int {
        // 각 음자리표의 맨 아래 줄: 높은음자리표는 E4, 낮은음자리표는 G2.
        let base = clef == .treble ? (letter: 2, octave: 4) : (letter: 4, octave: 2)

        // 음이름을 연속된 정수 하나로 다뤄야 옥타브 넘김이 저절로 처리된다.
        let absolute = base.letter + base.octave * 7 + diatonicStep
        let letter = ((absolute % 7) + 7) % 7
        let octave = Int(floor(Double(absolute) / 7.0))

        return (octave + 1) * 12 + semitonesFromC[letter] + accidental(forLetter: letter, fifths: fifths)
    }

    // MARK: - 내부

    /// C를 0으로 한 각 음이름의 반음 거리 — E~F와 B~C가 붙어 있는 게 여기서 드러난다.
    private static let semitonesFromC = [0, 2, 4, 5, 7, 9, 11]

    /// 샤프가 붙는 순서(F C G D A E B)와 플랫이 붙는 순서(B E A D G C F).
    /// 5도씩 올라가고(내려가고) 있다는 게 조표가 "5도권 개수"로 적히는 이유다.
    private static let sharpOrder = [3, 0, 4, 1, 5, 2, 6]
    private static let flatOrder = [6, 2, 5, 1, 4, 0, 3]

    /// **조표를 안 읽으면 음이 틀린다.** G장조에서 F 자리 음표는 F가 아니라 F#인데, 이건
    /// 조옮김 추정으로는 못 고친다 — 전체가 밀린 게 아니라 특정 음이름만 반음 다르기 때문이다.
    ///
    /// 조표는 음이름에 붙는 규칙이라 옥타브와 무관하게 같은 음이름 전부에 적용된다.
    private static func accidental(forLetter letter: Int, fifths: Int) -> Int {
        if fifths > 0 {
            return sharpOrder.prefix(min(fifths, 7)).contains(letter) ? 1 : 0
        }
        if fifths < 0 {
            return flatOrder.prefix(min(-fifths, 7)).contains(letter) ? -1 : 0
        }
        return 0
    }
}
