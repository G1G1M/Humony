import XCTest
@testable import Humony

/// 압축 MusicXML(`.mxl`) 읽기 (157절).
///
/// **왜 필요한가**: MuseScore의 MusicXML 내보내기 **기본값이 압축**이라, 사람들이 실제로
/// 손에 넣는 파일은 `.xml`보다 `.mxl`인 경우가 많다. 이걸 못 열면 "파일에서 악보를 못
/// 가져온다"가 된다.
final class CompressedMusicXMLTests: XCTestCase {

    private func data(ofResource name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "mxl"),
                                "테스트 번들에 \(name).mxl이 없다")
        return try Data(contentsOf: url)
    }

    /// F장조 네 음(F G A B)이 들어 있다 — 조표(플랫 하나) 때문에 마지막 B는 Bb(70)이다.
    /// 압축을 못 풀면 여기서 바로 드러난다.
    func testReadsAZipCompressedMusicXML() throws {
        let score = try ScoreImporter.parseCompressedMusicXML(try data(ofResource: "compressed-score"))

        XCTAssertEqual(score.notes.map(\.midiNote), [65, 67, 69, 71])
        XCTAssertEqual(score.keyFifths, -1)
    }

    /// zip은 압축 없이 그냥 담아둘 수도 있다 — 도구에 따라 이렇게 내보내기도 한다.
    func testReadsAnUncompressedZipEntry() throws {
        let score = try ScoreImporter.parseCompressedMusicXML(try data(ofResource: "stored-score"))

        XCTAssertEqual(score.notes.map(\.midiNote), [65, 67, 69, 71])
    }

    /// **`META-INF/container.xml`을 악보로 착각하면 안 된다.** 목차에서 먼저 나오지만
    /// 악보가 아니라 "어느 파일이 악보인지" 적어둔 안내문이다.
    func testSkipsTheContainerDescriptorAndFindsTheRealScore() throws {
        let entry = try ZipReader.firstEntry(in: try data(ofResource: "compressed-score")) { name in
            !name.hasPrefix("META-INF/") && name.lowercased().hasSuffix(".xml")
        }

        XCTAssertEqual(entry.name, "score.xml")
    }

    /// zip이 아닌 파일을 `.mxl`로 이름만 바꿔 넣은 경우.
    func testThrowsWhenTheFileIsNotAZipArchive() {
        let notAZip = Data("이건 zip이 아니다".utf8)

        XCTAssertThrowsError(try ScoreImporter.parseCompressedMusicXML(notAZip)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .malformed)
        }
    }
}
