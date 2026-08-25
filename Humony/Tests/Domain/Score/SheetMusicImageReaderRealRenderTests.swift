import XCTest
import ImageIO
@testable import Humony

/// **실제로 렌더된 악보 이미지**로 고정하는 회귀 테스트 (156절).
///
/// 다른 테스트들은 사각형과 타원으로 그린 합성 악보를 쓴다 — 알고리즘의 각 조각을 또렷하게
/// 검증하기엔 좋지만, 진짜 악보에는 합성 그림에 없는 것들이 있다(음자리표의 굵은 곡선,
/// 조표 기호, 얇은 테두리의 빈 머리, 오선을 관통하는 음표).
///
/// 여기 쓰는 세 장은 이 프로젝트가 이미 번들하고 있는 **VexFlow로 렌더한 진짜 악보**를
/// 헤드리스 브라우저로 찍은 것이다. 실기기에서 종이를 찍은 사진은 아니지만, 인쇄 악보와
/// 같은 모양·같은 규격이라 합성 그림이 못 잡는 실패를 잡아준다 — 실제로 두 가지를 잡았다.
/// - 높은음자리표의 곡선이 음표 머리 다섯 개로 잡히고, 그 헛것이 "첫 음표" 자리를 차지해
///   조표 검색 범위까지 잘려 샤프를 놓쳤다
/// - 빈 머리(2분음표)를 하나도 못 찾았다 — 오선을 먼저 지우면 머리 테두리에서 가장 얇은
///   좌우 끝이 함께 지워져 구멍이 새어나갔다(메우기와 지우기의 순서 문제였다)
final class SheetMusicImageReaderRealRenderTests: XCTestCase {

    private func score(fromResource name: String) throws -> ScoreImporter.ImportedScore {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "png"),
                                "테스트 번들에 \(name).png가 없다")
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let cgImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try SheetMusicImageReader.read(cgImage)
    }

    /// G장조 스케일(4분음표) — 조표를 읽지 못하면 네 번째 음이 F#(66)이 아니라 F(65)로
    /// 나온다. **조표가 실제로 음높이에 반영되는지**를 여기서 고정한다.
    func testReadsAGMajorScaleIncludingTheKeySignature() throws {
        let score = try score(fromResource: "gmajor")

        XCTAssertEqual(score.notes.map(\.midiNote), [60, 62, 64, 66, 67, 69, 71, 72])
        XCTAssertEqual(score.keyFifths, 1)
    }

    /// F장조 2분음표 — **빈 머리**(안이 뚫린 타원)와 **플랫 조표**를 함께 검증한다.
    /// 첫 음 B는 조표 때문에 Bb(70)이다.
    func testReadsHollowNoteheadsAndAFlatKeySignature() throws {
        let score = try score(fromResource: "fmajor")

        XCTAssertEqual(score.notes.map(\.midiNote), [70, 69, 67, 65, 64, 62])
        XCTAssertEqual(score.keyFifths, -1)
    }

    /// 두 단(system) — 위에서 아래로 이어 붙여야 곡의 순서가 된다.
    func testReadsTwoSystemsInReadingOrder() throws {
        let score = try score(fromResource: "twosystems")

        XCTAssertEqual(score.notes.map(\.midiNote), [60, 64, 67, 72, 71, 67, 64, 60])
        XCTAssertEqual(score.keyFifths, 0)
    }
}
