import Foundation
import CoreGraphics

enum Clef {
    case treble
    case bass
}

/// 오선보 좌표 계산 — MIDI 노트 하나가 5선 위 어디에(음자리표 기준) 놓여야 하는지 계산하는
/// 순수 함수 모음. 오선보의 핵심 규칙: 세로 위치는 반음(피치클래스) 단위가 아니라 **다이어토닉
/// 레터**(흰건반, 옥타브당 7개: C D E F G A B) 단위로 매겨진다 — 그래서 C와 C#은 정확히 같은
/// 자리에 놓이고, C#은 그 자리에 샵(#) 기호를 붙여서 구분한다. 이 v1은 단순화를 위해 플랫
/// 표기 없이 항상 샵으로만 표기한다(예: E♭는 D#로 표기됨) — 실제 조성별 표준 표기법(조표)까지
/// 구현하려면 조성마다 다른 승강표 규칙이 필요해서 프로토타입 범위를 넘어선다고 판단했다
/// (docs/CONCEPTS.md 56절).
struct StaffGeometry {
    let clef: Clef
    /// 5선의 각 줄 사이 간격(포인트).
    let lineSpacing: CGFloat
    /// 가장 아래(첫 번째) 줄의 y좌표.
    let bottomLineY: CGFloat

    struct NotePosition {
        /// 음표 머리(notehead)의 중심 y좌표.
        let y: CGFloat
        /// 이 음이 흰건반 사이(반음계) 음이라 샵 기호가 필요한지.
        let needsSharp: Bool
        /// 5선 밖으로 나가서 덧줄(ledger line)이 필요한 y좌표들.
        let ledgerLineYs: [CGFloat]
    }

    private var referenceMIDINote: Int {
        // 트레블(높은음자리표) 첫 줄 = E4, 베이스(낮은음자리표) 첫 줄 = G2 — 표준 규칙.
        clef == .treble ? 64 : 43
    }

    func position(for midiNote: Int) -> NotePosition {
        let (index, needsSharp) = Self.diatonicIndex(for: midiNote)
        let (referenceIndex, _) = Self.diatonicIndex(for: referenceMIDINote)
        let steps = index - referenceIndex
        let y = bottomLineY - CGFloat(steps) * (lineSpacing / 2)
        return NotePosition(y: y, needsSharp: needsSharp, ledgerLineYs: ledgerLineYs(forSteps: steps))
    }

    /// 5선(칸 0~8: 아래 줄~위 줄) 범위를 벗어난 자리(짝수 칸=줄 위치)마다 덧줄이 필요하다.
    private func ledgerLineYs(forSteps steps: Int) -> [CGFloat] {
        var result: [CGFloat] = []
        if steps < 0 {
            var s = -2
            while s >= steps {
                if s.isMultiple(of: 2) {
                    result.append(bottomLineY - CGFloat(s) * (lineSpacing / 2))
                }
                s -= 1
            }
        } else if steps > 8 {
            var s = 10
            while s <= steps {
                if s.isMultiple(of: 2) {
                    result.append(bottomLineY - CGFloat(s) * (lineSpacing / 2))
                }
                s += 1
            }
        }
        return result
    }

    // C D E F G A B의 피치클래스(흰건반) — 이 목록 안에 있으면 자연음, 아니면 바로 아래
    // 자연음의 샵으로 표기한다.
    private static let naturalPitchClasses = [0, 2, 4, 5, 7, 9, 11]

    /// MIDI 노트 -> (다이어토닉 절대 인덱스, 샵 필요 여부). 절대 인덱스는 `옥타브*7 + 레터인덱스`
    /// 로, 값이 클수록 음이 높다 — 두 음의 인덱스 차이가 곧 "오선에서 몇 칸 떨어져 있는지"다
    /// (MIDI 60 = C4 관례, 이 프로젝트 전반에서 쓰는 것과 동일).
    static func diatonicIndex(for midiNote: Int) -> (index: Int, needsSharp: Bool) {
        let octave = midiNote / 12 - 1
        let pitchClass = midiNote.mod(12)
        if let letterIndex = naturalPitchClasses.firstIndex(of: pitchClass) {
            return (octave * 7 + letterIndex, false)
        }
        // 반음계 음(검은건반)은 항상 자연음이 그 아래(피치클래스가 더 작은 값)에 있다 —
        // 0(C)이 목록에 항상 있어서 강제 언래핑이 안전하다.
        let letterIndex = naturalPitchClasses.lastIndex(where: { $0 < pitchClass })!
        return (octave * 7 + letterIndex, true)
    }
}
