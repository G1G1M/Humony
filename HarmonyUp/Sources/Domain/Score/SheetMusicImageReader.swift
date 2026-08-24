import CoreGraphics
import Foundation

/// 악보 **사진** 한 장을 음 목록으로 바꾼다 (156절) — 오선·머리·조표 세 조각을 묶는다.
///
/// **왜 이게 가능한가**: 일반적인 악보 인식(OMR)은 딥러닝 없이는 어렵다고 여겨지는데, 그건
/// 박자·음가·이음줄·셈여림까지 전부 복원하려 하기 때문이다. 이 앱에 필요한 건 **음높이
/// 순서뿐이다** — 리듬은 실제로 부른 그대로 쓴다(155절). 그러면 남는 문제는 "타원이 어디
/// 있나"와 "앞머리에 샤프가 몇 개인가"로 줄어들고, 둘 다 고전적인 이미지 처리로 풀린다.
///
/// **그래도 사진은 사진이다.** 잘못 읽을 수 있고, 그때를 대비한 것이 155절의 포기 관문
/// 셋이다 — 엉뚱하게 읽은 악보는 조옮김 신뢰도와 일치율에서 걸러져 교정이 적용되지 않는다.
///
/// **지금의 한계**(문서와 안내 문구에 그대로 반영한다)
/// - **높은음자리표로 가정한다.** 노래 멜로디 악보는 거의 다 높은음자리표다
/// - 곡 중간의 임시표(#/♭/♮)는 안 읽는다 — 조표만 본다
/// - 여러 성부가 겹친 악보(피아노 반주 등)는 위쪽 성부만 얻는 걸 보장하지 않는다
enum SheetMusicImageReader {

    /// 사진에서는 음가를 읽지 않으므로 모든 음에 같은 값을 준다 — **모르는 걸 지어내지 않는다.**
    /// 정렬은 순서만 쓰고, 조성은 조표에서 오므로 이 값이 결과를 바꾸지 않는다.
    private static let nominalDuration = 1.0

    static func read(_ cgImage: CGImage) throws -> ScoreImporter.ImportedScore {
        guard let binary = SheetMusicImagePreprocessor.binarize(cgImage) else {
            throw ScoreImporter.ImportError.malformed
        }
        return try read(binary: binary)
    }

    static func read(binary: BinaryImage) throws -> ScoreImporter.ImportedScore {
        // 손으로 든 폰은 반드시 조금 기운다 — 펴지 않으면 오선 검출부터 실패한다.
        let straightened = SheetMusicImagePreprocessor.deskewed(binary)

        let staves = StaffDetector.detect(in: straightened)
        guard !staves.isEmpty else { throw ScoreImporter.ImportError.noStaffFound }

        var fifths: Int?
        var notes: [PitchedNote] = []

        for staff in staves {
            let heads = NoteheadDetector.detect(in: straightened, staff: staff)
            guard !heads.isEmpty else { continue }

            // 조표는 단마다 반복되지만 첫 단에서 읽히면 그걸 쓴다 — 곡 중간에 조가 바뀌는
            // 악보는 이번 범위 밖이다(155절 MusicXML 파서도 첫 조표만 쓴다).
            if fifths == nil, let firstHeadX = heads.first?.x {
                fifths = KeySignatureReader.fifths(in: straightened, staff: staff, beforeX: firstHeadX)
            }

            for head in heads {
                let step = StaffPitchMapper.diatonicStep(y: head.y, staff: staff)
                notes.append(PitchedNote(
                    midiNote: StaffPitchMapper.midiNote(diatonicStep: step, clef: .treble, fifths: fifths ?? 0),
                    duration: nominalDuration
                ))
            }
        }

        guard !notes.isEmpty else { throw ScoreImporter.ImportError.noNotesFound }

        return ScoreImporter.ImportedScore(notes: notes, keyFifths: fifths, keyMode: nil)
    }
}
