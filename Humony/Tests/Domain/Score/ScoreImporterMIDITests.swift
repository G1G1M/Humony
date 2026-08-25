import XCTest
@testable import Humony

/// MIDI 불러오기(155절). MusicXML과 같은 계약을 지켜야 한다 — 길이는 4분음표 = 1.0인
/// 상대값, 화음은 가장 높은 음만, 조표는 있으면 그대로 쓰고 없으면 nil.
///
/// 픽스처를 파일로 두지 않고 **바이트로 조립한다**. 스탠다드 MIDI 파일은 형식이 단순해서
/// 손으로 만들 수 있고, 그래야 "이 테스트가 무엇을 담고 있는지"가 테스트 안에서 다 보인다
/// (바이너리 픽스처는 리뷰도 수정도 안 된다).
final class ScoreImporterMIDITests: XCTestCase {

    /// 4분음표 하나에 들어가는 틱 수. 실제 파일에서 흔히 쓰는 값이다.
    private let ticksPerQuarter = 480

    // MARK: - 음높이와 길이

    /// 가장 기본. MIDI의 시간 단위는 틱이지만 우리가 쓰는 단위는 박이다 — `MusicSequence`가
    /// 헤더의 division으로 나눠 박 단위로 돌려주므로, 4분음표는 1.0, 8분음표는 0.5가 된다.
    func testReadsPitchesAndBeatDurations() throws {
        let data = midiFile(tracks: [track(events:
            noteEvents(67, at: 0, ticks: ticksPerQuarter)
            + noteEvents(69, at: ticksPerQuarter, ticks: ticksPerQuarter / 2)
            + noteEvents(66, at: ticksPerQuarter * 2, ticks: ticksPerQuarter * 2)
        )])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [67, 69, 66])
        assertDurations(score.notes, equal: [1.0, 0.5, 2.0])
    }

    /// 트랙 안에서 음이 시간순으로 적혀 있지 않아도(편집기가 그렇게 쓰는 경우가 있다)
    /// 결과는 부를 순서, 즉 온셋 순서여야 한다. 정렬은 뒤 단계(악보와 부른 멜로디를 맞추는
    /// 정렬)의 전제다.
    func testNotesComeOutInOnsetOrder() throws {
        let data = midiFile(tracks: [track(events:
            noteEvents(72, at: ticksPerQuarter * 2, ticks: ticksPerQuarter)
            + noteEvents(60, at: 0, ticks: ticksPerQuarter)
            + noteEvents(64, at: ticksPerQuarter, ticks: ticksPerQuarter)
        )])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [60, 64, 72])
    }

    // MARK: - 화음

    /// MusicXML은 `<chord/>` 태그로 화음을 알려주지만 MIDI에는 그런 표시가 없다 —
    /// **같은 자리에서 시작하는 음들**이 화음이다. 멜로디는 보통 화음의 맨 위라서 최고음만 남긴다.
    func testSimultaneousNotesKeepOnlyTheHighest() throws {
        let data = midiFile(tracks: [track(events:
            noteEvents(60, at: 0, ticks: ticksPerQuarter)
            + noteEvents(64, at: 0, ticks: ticksPerQuarter)
            + noteEvents(67, at: 0, ticks: ticksPerQuarter)
            + noteEvents(65, at: ticksPerQuarter, ticks: ticksPerQuarter)
        )])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [67, 65])
    }

    /// 사람이 연주해 녹음한 MIDI는 화음이 정확히 같은 틱에 찍히지 않는다(몇 ms씩 어긋난다).
    /// 아주 가까운 온셋은 같은 화음으로 묶어야 한다 — 안 그러면 화음 하나가 32분음표
    /// 여러 개로 쪼개져 멜로디에 없는 음이 줄줄이 들어간다.
    func testNearlySimultaneousNotesAreTreatedAsOneChord() throws {
        let jitter = ticksPerQuarter / 40   // 12틱 ≈ 25ms
        let data = midiFile(tracks: [track(events:
            noteEvents(60, at: 0, ticks: ticksPerQuarter)
            + noteEvents(67, at: jitter, ticks: ticksPerQuarter)
        )])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [67])
    }

    /// 반대로, 앞 음이 채 끝나기 전에 다음 음이 시작하는 것(레가토·페달)은 화음이 아니다.
    /// 온셋이 뚜렷이 다르면 서로 다른 음으로 남아야 한다.
    func testOverlappingButSeparateOnsetsStayTwoNotes() throws {
        let data = midiFile(tracks: [track(events:
            noteEvents(60, at: 0, ticks: ticksPerQuarter * 2)          // 길게 끌고
            + noteEvents(64, at: ticksPerQuarter, ticks: ticksPerQuarter)  // 그 위에서 다음 음 시작
        )])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [60, 64])
    }

    // MARK: - 트랙 고르기

    /// 반주가 같이 들어 있는 파일에서는 멜로디 줄만 필요하다. MusicXML의 파트 고르기와
    /// 같은 규칙 — 평균 음높이가 가장 높은 트랙을 멜로디로 본다.
    func testPicksTheHighestSoundingTrack() throws {
        let accompaniment = track(events:
            noteEvents(48, at: 0, ticks: ticksPerQuarter)
            + noteEvents(50, at: ticksPerQuarter, ticks: ticksPerQuarter)
        )
        let melody = track(events:
            noteEvents(72, at: 0, ticks: ticksPerQuarter)
            + noteEvents(74, at: ticksPerQuarter, ticks: ticksPerQuarter)
        )
        let data = midiFile(format: 1, tracks: [accompaniment, melody])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [72, 74])
    }

    // MARK: - 조표

    /// 조표는 추정이 아니라 파일에 적힌 사실이다. 이게 있으면 152절의 "조성이 반음 위로
    /// 뒤집힘"(오디오에서 추정하다 생긴 문제)을 아예 건너뛴다.
    func testReadsMajorKeySignature() throws {
        let data = midiFile(tracks: [track(events:
            [(tick: 0, bytes: keySignatureEvent(sharps: 1, minor: false))]
            + noteEvents(67, at: 0, ticks: ticksPerQuarter)
        )])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertEqual(score.keyFifths, 1)
        XCTAssertEqual(score.keyMode, .major)
        XCTAssertEqual(score.key?.tonicPitchClass, 7)      // G장조
        XCTAssertEqual(score.key?.confidence, 1.0)
    }

    /// 플랫 조표는 음수로 적힌다(signed byte). 단조 표시도 같이 읽는다.
    func testReadsFlatMinorKeySignature() throws {
        let data = midiFile(tracks: [track(events:
            [(tick: 0, bytes: keySignatureEvent(sharps: -3, minor: true))]
            + noteEvents(60, at: 0, ticks: ticksPerQuarter)
        )])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertEqual(score.keyFifths, -3)
        XCTAssertEqual(score.keyMode, .minor)
        XCTAssertEqual(score.key?.tonicPitchClass, 0)      // 플랫 3개 단조 = C단조
    }

    /// 조표가 없으면 **지어내지 않는다**. 모른다는 걸 C장조로 채우면 뒤 단계가 그 값을
    /// "악보에서 온 확실한 조성"으로 믿어버린다.
    func testKeyIsNilWhenThereIsNoKeySignature() throws {
        let data = midiFile(tracks: [track(events: noteEvents(60, at: 0, ticks: ticksPerQuarter))])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertNil(score.keyFifths)
        XCTAssertNil(score.key)
    }

    /// 조표가 멜로디 트랙이 아니라 첫 트랙(반주 트랙 등)에만 적힌 파일이 흔하다 —
    /// 조표는 곡 전체의 성질이므로 어느 트랙에서 나왔든 쓴다.
    func testKeySignatureFromAnotherTrackIsStillUsed() throws {
        let accompaniment = track(events:
            [(tick: 0, bytes: keySignatureEvent(sharps: 2, minor: false))]
            + noteEvents(48, at: 0, ticks: ticksPerQuarter)
        )
        let melody = track(events: noteEvents(74, at: 0, ticks: ticksPerQuarter))
        let data = midiFile(format: 1, tracks: [accompaniment, melody])

        let score = try ScoreImporter.parseMIDI(data)

        XCTAssertEqual(score.notes.map(\.midiNote), [74])
        XCTAssertEqual(score.key?.tonicPitchClass, 2)      // D장조
    }

    // MARK: - 실패

    func testThrowsWhenThereAreNoNotes() {
        let data = midiFile(tracks: [track(events: [])])

        XCTAssertThrowsError(try ScoreImporter.parseMIDI(data)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .noNotesFound)
        }
    }

    func testThrowsWhenTheDataIsNotMIDI() {
        let data = Data("이건 MIDI가 아니다".utf8)

        XCTAssertThrowsError(try ScoreImporter.parseMIDI(data)) { error in
            XCTAssertEqual(error as? ScoreImporter.ImportError, .malformed)
        }
    }

    // MARK: - 확장자로 갈라 읽기

    /// `.mid`/`.midi`도 `load(from:)`이 받아야 한다 — 화면에서는 확장자만 보고 고른다.
    func testLoadsMIDIByFileExtension() throws {
        let data = midiFile(tracks: [track(events: noteEvents(67, at: 0, ticks: ticksPerQuarter))])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("score-importer-test-\(UUID().uuidString).mid")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let score = try ScoreImporter.load(from: url)

        XCTAssertEqual(score.notes.map(\.midiNote), [67])
    }

    // MARK: - 픽스처 조립

    private func assertDurations(_ notes: [ScoreImporter.Note], equal expected: [Double],
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(notes.count, expected.count, file: file, line: line)
        for (note, want) in zip(notes, expected) {
            // 길이는 Float32 박으로 들어오므로 정확히 같길 기대할 수 없다.
            XCTAssertEqual(note.duration, want, accuracy: 0.001, file: file, line: line)
        }
    }

    private typealias TrackEvent = (tick: Int, bytes: [UInt8])

    /// note on/off 한 쌍. 절대 틱으로 만들어두고 트랙을 조립할 때 델타로 바꾼다.
    private func noteEvents(_ midiNote: Int, at tick: Int, ticks: Int) -> [TrackEvent] {
        [
            (tick, [0x90, UInt8(midiNote), 100]),
            (tick + ticks, [0x80, UInt8(midiNote), 0])
        ]
    }

    /// 조표 메타 이벤트. 샤프 개수는 signed byte(플랫이 음수), 두 번째 바이트가 장/단조다.
    private func keySignatureEvent(sharps: Int, minor: Bool) -> [UInt8] {
        [0xFF, 0x59, 0x02, UInt8(bitPattern: Int8(sharps)), minor ? 1 : 0]
    }

    /// 이벤트를 시간순으로 정렬해 델타 타임으로 바꾸고 `MTrk` 청크로 감싼다.
    private func track(events: [TrackEvent]) -> [UInt8] {
        // 같은 틱에 있는 이벤트는 적어준 순서를 지켜야 한다(화음 테스트가 그 순서에 기댄다).
        let ordered = events.enumerated()
            .sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map(\.element)

        var body: [UInt8] = []
        var previousTick = 0
        for event in ordered {
            body += variableLength(event.tick - previousTick) + event.bytes
            previousTick = event.tick
        }
        body += variableLength(0) + [0xFF, 0x2F, 0x00]      // end of track

        return Array("MTrk".utf8) + bigEndian32(body.count) + body
    }

    private func midiFile(format: Int = 0, tracks: [[UInt8]]) -> Data {
        var bytes = Array("MThd".utf8) + bigEndian32(6)
            + bigEndian16(format) + bigEndian16(tracks.count) + bigEndian16(ticksPerQuarter)
        for chunk in tracks { bytes += chunk }
        return Data(bytes)
    }

    /// MIDI의 가변 길이 수: 7비트씩 끊어 담고, 마지막 바이트만 최상위 비트가 0이다.
    private func variableLength(_ value: Int) -> [UInt8] {
        var bytes = [UInt8(value & 0x7F)]
        var remainder = value >> 7
        while remainder > 0 {
            bytes.insert(UInt8((remainder & 0x7F) | 0x80), at: 0)
            remainder >>= 7
        }
        return bytes
    }

    private func bigEndian16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private func bigEndian32(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}
