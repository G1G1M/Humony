import XCTest
@testable import Humony

/// `ScoreImporter.load(from:)` — 실제 파일 URL로 들어오는 경로 (155·156절).
///
/// 파싱 자체는 각 파서 테스트가 덮고 있지만, **파일에서 읽어 확장자로 갈라내는 길**은 이
/// 테스트가 유일하게 지난다. 사용자가 "파일에서 xml을 못 받아온다"고 해서 이 경로부터 고정했다.
final class ScoreImporterFileLoadTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("score-load-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ contents: String, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private var minimalMusicXML: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part id="P1">
            <measure number="1">
              <attributes><divisions>1</divisions><key><fifths>1</fifths><mode>major</mode></key></attributes>
              <note><pitch><step>G</step><octave>4</octave></pitch><duration>1</duration></note>
              <note><pitch><step>A</step><octave>4</octave></pitch><duration>1</duration></note>
            </measure>
          </part>
        </score-partwise>
        """
    }

    /// MuseScore가 내보내는 기본 확장자.
    func testLoadsAMusicXMLFile() throws {
        let url = try write(minimalMusicXML, as: "song.musicxml")

        let score = try ScoreImporter.load(from: url)

        XCTAssertEqual(score.notes.map(\.midiNote), [67, 69])
        XCTAssertEqual(score.keyFifths, 1)
    }

    /// **같은 내용을 `.xml`로 저장한 경우** — 오래된 도구나 "비압축 MusicXML"로 내보내면 이쪽이다.
    func testLoadsTheSameContentWithAPlainXMLExtension() throws {
        let url = try write(minimalMusicXML, as: "song.xml")

        let score = try ScoreImporter.load(from: url)

        XCTAssertEqual(score.notes.map(\.midiNote), [67, 69])
    }

    /// 확장자 대소문자가 섞여 들어와도 같아야 한다(파일 앱에서 흔하다).
    func testExtensionMatchingIsCaseInsensitive() throws {
        let url = try write(minimalMusicXML, as: "SONG.XML")

        XCTAssertNoThrow(try ScoreImporter.load(from: url))
    }

    /// 지원하지 않는 형식은 "무엇을 넣어야 하는지"를 알려주는 에러로 떨어져야 한다.
    func testUnsupportedExtensionThrowsUnsupportedFileType() throws {
        let url = try write("not a score", as: "song.pdf")

        XCTAssertThrowsError(try ScoreImporter.load(from: url)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .unsupportedFileType)
        }
    }

    /// 확장자는 맞는데 내용이 악보가 아닌 경우.
    func testXMLThatIsNotAScoreThrowsNoNotesFound() throws {
        let url = try write("<?xml version=\"1.0\"?><root><hello/></root>", as: "song.xml")

        XCTAssertThrowsError(try ScoreImporter.load(from: url)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .noNotesFound)
        }
    }
}
