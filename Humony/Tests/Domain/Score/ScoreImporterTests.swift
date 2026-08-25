import XCTest
@testable import Humony

/// 악보 파일(MusicXML)을 "정답지"로 읽어들이는 단계의 테스트 (155절).
///
/// 이 단계에서 필요한 건 **음높이 순서**와 **조표**뿐이다 — 부른 리듬을 그대로 유지하는 게
/// 목적이라 악보의 템포는 쓰지 않는다. 그래서 길이는 초가 아니라 "4분음표 = 1.0"인 상대값이고,
/// 조성 판별에 쓸 가중치로만 쓰인다.
final class ScoreImporterTests: XCTestCase {

    // MARK: - 픽스처 헬퍼

    private func musicXML(attributes: String, notes: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part id="P1">
            <measure number="1">
              \(attributes)
              \(notes)
            </measure>
          </part>
        </score-partwise>
        """
        return Data(xml.utf8)
    }

    private func pitchedNote(_ step: String, _ octave: Int, alter: Int? = nil, duration: Int) -> String {
        let alterTag = alter.map { "<alter>\($0)</alter>" } ?? ""
        return """
        <note><pitch><step>\(step)</step>\(alterTag)<octave>\(octave)</octave></pitch><duration>\(duration)</duration></note>
        """
    }

    // MARK: - 음높이와 길이

    /// `<divisions>`는 "4분음표 하나가 몇 division인가"다. 여기서는 4이므로 duration 4 = 4분음표.
    /// 임시표(`<alter>`)는 반음 단위로 더한다 — F#4는 66.
    func testReadsPitchesAndDurationsRelativeToQuarterNote() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>4</divisions></attributes>",
            notes: pitchedNote("G", 4, duration: 4)
                + pitchedNote("A", 4, duration: 2)
                + pitchedNote("F", 4, alter: 1, duration: 8)
        )

        let score = try ScoreImporter.parseMusicXML(data)

        XCTAssertEqual(score.notes, [
            .init(midiNote: 67, duration: 1.0),   // G4, 4분음표
            .init(midiNote: 69, duration: 0.5),   // A4, 8분음표
            .init(midiNote: 66, duration: 2.0)    // F#4, 2분음표
        ])
    }

    /// 쉼표는 음이 아니다 — 정렬은 부른 음과 악보 음을 순서대로 맞추는 일이라 쉼표가 끼면 어긋난다.
    func testSkipsRests() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>1</divisions></attributes>",
            notes: pitchedNote("C", 4, duration: 1)
                + "<note><rest/><duration>2</duration></note>"
                + pitchedNote("D", 4, duration: 1)
        )

        let score = try ScoreImporter.parseMusicXML(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [60, 62])
    }

    /// 화음(`<chord/>`)에서는 **가장 높은 음만** 남긴다. 사람이 부르는 건 멜로디고, 멜로디는
    /// 보통 화음의 맨 위에 있다. (MusicXML은 화음 안 음의 순서를 규정하지 않아서 "첫 음"으로
    /// 고르면 파일마다 다른 답이 나온다.)
    func testKeepsOnlyTheTopNoteOfAChord() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>1</divisions></attributes>",
            notes: pitchedNote("C", 4, duration: 1)
                + "<note><chord/><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration></note>"
                + "<note><chord/><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration></note>"
                + pitchedNote("B", 3, duration: 1)
        )

        let score = try ScoreImporter.parseMusicXML(data)

        XCTAssertEqual(score.notes, [
            .init(midiNote: 67, duration: 1.0),   // C-E-G 중 G4
            .init(midiNote: 59, duration: 1.0)
        ])
    }

    /// 이음줄(tie)로 이어진 음은 **한 음이다.** 나누어 두면 정렬에서 "같은 음을 두 번 불렀다"로
    /// 보여 뒤 음들이 통째로 밀린다. `<tie type="stop">`은 앞 음의 길이에 더한다.
    func testTiedNotesBecomeOneNoteWithSummedDuration() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>2</divisions></attributes>",
            notes: """
            <note><pitch><step>G</step><octave>4</octave></pitch><duration>2</duration><tie type="start"/></note>
            <note><pitch><step>G</step><octave>4</octave></pitch><duration>4</duration><tie type="stop"/></note>
            """ + pitchedNote("A", 4, duration: 2)
        )

        let score = try ScoreImporter.parseMusicXML(data)

        XCTAssertEqual(score.notes, [
            .init(midiNote: 67, duration: 3.0),   // 1.0 + 2.0
            .init(midiNote: 69, duration: 1.0)
        ])
    }

    /// 꾸밈음(`<grace/>`)은 `<duration>`이 없다 — 길이 0으로 들어오면 정렬에 잡음만 더한다.
    func testSkipsGraceNotes() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>1</divisions></attributes>",
            notes: "<note><grace/><pitch><step>D</step><octave>4</octave></pitch></note>"
                + pitchedNote("C", 4, duration: 1)
        )

        let score = try ScoreImporter.parseMusicXML(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [60])
    }

    // MARK: - 여러 성부 / 여러 파트

    /// 한 파트 안에 성부가 여럿이면(`<voice>`) **첫 성부만** 쓴다. 반주 성부까지 섞으면 멜로디
    /// 순서가 깨진다. `<backup>`으로 시간을 되감아 아래 성부를 적는 흔한 표기도 이걸로 걸러진다.
    func testUsesOnlyTheFirstVoiceWithinAPart() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>1</divisions></attributes>",
            notes: """
            <note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice></note>
            <note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice></note>
            <backup><duration>2</duration></backup>
            <note><pitch><step>C</step><octave>3</octave></pitch><duration>2</duration><voice>2</voice></note>
            """
        )

        let score = try ScoreImporter.parseMusicXML(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [67, 69])
    }

    /// 파트가 여럿이면 **평균 음높이가 가장 높은 파트**를 멜로디로 본다(합창 악보의 소프라노,
    /// 피아노 반주가 붙은 성악 악보의 노래 줄).
    func testPicksTheHighestSoundingPartWhenThereAreSeveral() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part id="P1">
            <measure number="1">
              <attributes><divisions>1</divisions></attributes>
              <note><pitch><step>C</step><octave>3</octave></pitch><duration>1</duration></note>
              <note><pitch><step>E</step><octave>3</octave></pitch><duration>1</duration></note>
            </measure>
          </part>
          <part id="P2">
            <measure number="1">
              <attributes><divisions>1</divisions></attributes>
              <note><pitch><step>C</step><octave>5</octave></pitch><duration>1</duration></note>
              <note><pitch><step>D</step><octave>5</octave></pitch><duration>1</duration></note>
            </measure>
          </part>
        </score-partwise>
        """

        let score = try ScoreImporter.parseMusicXML(Data(xml.utf8))

        XCTAssertEqual(score.notes.map(\.midiNote), [72, 74])
    }

    // MARK: - 조표

    /// 조표는 5도권 개수(`<fifths>`)로 적힌다. 장조 으뜸음은 `fifths * 7 (mod 12)` —
    /// 샤프 하나면 G장조. **악보에 적힌 조성은 오디오 추정보다 확실하므로 신뢰도는 1이다.**
    func testReadsKeySignatureForMajor() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>1</divisions><key><fifths>1</fifths><mode>major</mode></key></attributes>",
            notes: pitchedNote("G", 4, duration: 1)
        )

        let score = try ScoreImporter.parseMusicXML(data)
        let key = try XCTUnwrap(score.key)

        XCTAssertEqual(key.tonicPitchClass, 7)      // G
        XCTAssertEqual(key.mode, .major)
        XCTAssertEqual(key.confidence, 1.0)
    }

    /// 플랫 조표와 단조. 나란한단조는 장조 으뜸음보다 3반음 아래다 — 플랫 하나(F장조, 5)면 D단조(2).
    func testReadsKeySignatureForMinor() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>1</divisions><key><fifths>-1</fifths><mode>minor</mode></key></attributes>",
            notes: pitchedNote("D", 4, duration: 1)
        )

        let score = try ScoreImporter.parseMusicXML(data)
        let key = try XCTUnwrap(score.key)

        XCTAssertEqual(key.tonicPitchClass, 2)      // D
        XCTAssertEqual(key.mode, .minor)
    }

    /// `<mode>`가 없는 악보도 많다 — 조표만 있으면 장조로 읽는다(가장 흔한 표기).
    func testDefaultsToMajorWhenModeIsMissing() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>1</divisions><key><fifths>0</fifths></key></attributes>",
            notes: pitchedNote("C", 4, duration: 1)
        )

        let score = try ScoreImporter.parseMusicXML(data)
        let key = try XCTUnwrap(score.key)

        XCTAssertEqual(key.tonicPitchClass, 0)
        XCTAssertEqual(key.mode, .major)
    }

    /// 조표가 아예 없으면 nil이다 — **모른다를 C장조로 지어내면 안 된다.** 그러면 뒤 단계가
    /// 틀린 조성을 "악보에서 온 확실한 값"으로 믿어버린다.
    func testKeyIsNilWhenTheScoreHasNoKeySignature() throws {
        let data = musicXML(
            attributes: "<attributes><divisions>1</divisions></attributes>",
            notes: pitchedNote("C", 4, duration: 1)
        )

        let score = try ScoreImporter.parseMusicXML(data)

        XCTAssertNil(score.key)
    }

    // MARK: - 잘못된 입력

    func testThrowsWhenTheFileIsNotXML() {
        let data = Data("이건 악보가 아니다".utf8)

        XCTAssertThrowsError(try ScoreImporter.parseMusicXML(data)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .malformed)
        }
    }

    /// 파싱은 됐는데 음이 하나도 없는 경우(쉼표만 있는 파일, 빈 파트). 조용히 빈 악보를 돌려주면
    /// 뒤 단계가 "악보가 붙었다"고 믿고 전부 누락으로 처리한다.
    func testThrowsWhenThereAreNoNotes() {
        let data = musicXML(
            attributes: "<attributes><divisions>1</divisions></attributes>",
            notes: "<note><rest/><duration>4</duration></note>"
        )

        XCTAssertThrowsError(try ScoreImporter.parseMusicXML(data)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .noNotesFound)
        }
    }

    func testThrowsForUnsupportedFileTypes() {
        let url = URL(fileURLWithPath: "/tmp/score.pdf")

        XCTAssertThrowsError(try ScoreImporter.load(from: url)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .unsupportedFileType)
        }
    }
}
