import AudioToolbox
import Foundation

/// 악보 파일을 읽어 "정답지"로 쓸 음 목록과 조표를 뽑는다 (155절).
///
/// **왜 악보를 받는가**: 지금까지 채보 오류는 전부 "오디오만 보고 무슨 음인지 알아내야 한다"는
/// 근본 난이도에서 나왔다(149절 A#3 오탐, 152절 조성이 반음 위로 번짐, 153절 떨림이 독립
/// 음표가 돼 화음이 반음 튐). 부를 곡의 악보가 있으면 문제가 **인식에서 정렬로** 바뀐다 —
/// "이게 무슨 음이지?"가 아니라 "이 음이 악보의 어느 음이지?"다.
///
/// **서드파티를 안 쓴다**: MusicXML은 XML이라 `XMLParser`로 충분하고, MIDI는 애플의
/// `AudioToolbox`(`MusicSequence`)가 이미 읽어준다. `CLAUDE.md`의 "피치 검출 라이브러리
/// 금지(학습 목적)" 규칙과 부딪히지 않고, 124절 WORLD 때 했던 라이선스 검토도 필요 없다.
///
/// **길이는 초가 아니라 4분음표 = 1.0인 상대값이다.** 교정은 음높이만 악보로 스냅하고
/// 타이밍은 부른 그대로 두기 때문에(실제로 부른 리듬이 화음 타이밍의 기준이다) 악보의
/// 템포는 필요 없다. 이 길이는 조성 판별의 가중치로만 쓰인다.
enum ScoreImporter {

    /// 악보에서 읽은 음. 길이는 **4분음표 = 1.0인 상대값**이다(위 주석 참고).
    /// 부른 음과 같은 타입(`PitchedNote`)으로 말해야 조옮김 추정·정렬에서 나란히 놓을 수 있다.
    typealias Note = PitchedNote

    struct ImportedScore: Equatable {
        let notes: [Note]
        /// 조표의 5도권 개수. 샤프가 양수, 플랫이 음수(예: 1 = 샤프 하나 = G장조/E단조).
        let keyFifths: Int?
        let keyMode: KeyDetector.Mode?

        /// 악보에 조표가 적혀 있으면 그대로 조성으로 쓴다.
        ///
        /// **신뢰도가 1인 이유**: 이건 오디오에서 추정한 값이 아니라 악보에 인쇄된 사실이다.
        /// 152절의 "조성이 반음 위로 뒤집힘"은 낮은 진폭에서 pitch-class 분포가 번져 생긴
        /// 문제였는데, 조표가 있으면 그 추정 자체를 건너뛴다.
        var key: KeyDetector.DetectedKey? {
            guard let keyFifths else { return nil }
            let mode = keyMode ?? .major
            // 5도를 한 번 올릴 때마다 으뜸음이 7반음 위로 간다(C→G→D…). 음수(플랫)도 같은 식.
            let majorTonic = ((keyFifths * 7) % 12 + 12) % 12
            // 나란한단조의 으뜸음은 장조보다 3반음 아래 = 9반음 위.
            let tonic = mode == .major ? majorTonic : (majorTonic + 9) % 12
            return KeyDetector.DetectedKey(tonicPitchClass: tonic, mode: mode, confidence: 1.0)
        }
    }

    enum ImportError: Error, Equatable {
        case unsupportedFileType
        case malformed
        case noNotesFound
    }

    /// 지금 지원하는 확장자. `.mxl`(zip으로 압축된 MusicXML)과 PDF는 아직이다 —
    /// PDF는 스캔본이면 딥러닝 OMR이 필요해 온디바이스 원칙과 부딪힌다.
    private static let musicXMLExtensions: Set<String> = ["musicxml", "xml"]
    private static let midiExtensions: Set<String> = ["mid", "midi"]

    static func load(from url: URL) throws -> ImportedScore {
        let fileExtension = url.pathExtension.lowercased()
        let isMIDI = midiExtensions.contains(fileExtension)
        guard isMIDI || musicXMLExtensions.contains(fileExtension) else {
            throw ImportError.unsupportedFileType
        }

        guard let data = try? Data(contentsOf: url) else { throw ImportError.malformed }
        return isMIDI ? try parseMIDI(data) : try parseMusicXML(data)
    }

    static func parseMusicXML(_ data: Data) throws -> ImportedScore {
        let parser = XMLParser(data: data)
        let handler = MusicXMLHandler()
        parser.delegate = handler

        guard parser.parse() else { throw ImportError.malformed }
        guard let melody = handler.melodyPart, !melody.notes.isEmpty else { throw ImportError.noNotesFound }

        return ImportedScore(notes: melody.notes, keyFifths: melody.fifths, keyMode: melody.mode)
    }

    // MARK: - MusicXML 파싱

    /// `XMLParser`는 SAX 방식(요소를 만날 때마다 콜백)이라 상태를 직접 들고 있어야 한다.
    /// 파트를 전부 모아뒀다가 끝에서 하나를 고르는 이유는, 어느 파트가 멜로디인지는 모든
    /// 음을 봐야 알 수 있기 때문이다.
    private final class MusicXMLHandler: NSObject, XMLParserDelegate {

        struct Part {
            var notes: [Note] = []
            var fifths: Int?
            var mode: KeyDetector.Mode?
            /// 이 파트에서 처음 만난 성부 번호. 이후 다른 성부의 음은 버린다.
            var firstVoice: String?
        }

        private var parts: [Part] = []
        private var divisions: Double = 1

        private var text = ""

        // 현재 <note> 상태
        private var inNote = false
        private var step: String?
        private var alter = 0
        private var octave: Int?
        private var noteDuration: Double?
        private var isRest = false
        private var isChord = false
        private var isGrace = false
        private var noteVoice: String?
        private var tieStop = false

        private var inKey = false
        private var pendingFifths: Int?
        private var pendingMode: KeyDetector.Mode?

        /// 파트가 여럿이면 **평균 음높이가 가장 높은 파트**를 멜로디로 본다 — 합창 악보의
        /// 소프라노, 피아노 반주가 붙은 성악 악보의 노래 줄이 여기에 해당한다.
        var melodyPart: Part? {
            parts.filter { !$0.notes.isEmpty }
                .max { averagePitch($0) < averagePitch($1) }
        }

        private func averagePitch(_ part: Part) -> Double {
            guard !part.notes.isEmpty else { return -.infinity }
            return Double(part.notes.map(\.midiNote).reduce(0, +)) / Double(part.notes.count)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""

            switch elementName {
            case "part":
                parts.append(Part())
                divisions = 1                  // 파트마다 새로 선언된다
            case "note":
                resetNoteState()
                inNote = true
            case "rest" where inNote:
                isRest = true
            case "chord" where inNote:
                isChord = true
            case "grace" where inNote:
                isGrace = true
            case "tie", "tied":
                // <tie>는 소리, <tied>는 표기용이다. 어느 쪽으로 적혀 있든 "이어진 음"으로 받는다.
                if inNote, attributes["type"] == "stop" { tieStop = true }
            case "key":
                inKey = true
                pendingFifths = nil
                pendingMode = nil
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

            switch elementName {
            case "divisions":
                // "4분음표 하나가 몇 division인가". 0이면 나눗셈이 깨지므로 무시한다.
                if let parsed = Double(value), parsed > 0 { divisions = parsed }
            case "fifths" where inKey:
                pendingFifths = Int(value)
            case "mode" where inKey:
                pendingMode = value.lowercased() == "minor" ? .minor : .major
            case "key":
                inKey = false
                // 곡 중간에 조가 바뀌는 악보도 있지만, 여기서는 **첫 조표만** 쓴다 —
                // 정렬은 곡 전체를 하나의 조성으로 다루기 때문이다.
                if !parts.isEmpty, parts[parts.count - 1].fifths == nil {
                    parts[parts.count - 1].fifths = pendingFifths
                    parts[parts.count - 1].mode = pendingMode
                }
            case "step" where inNote:
                step = value
            case "alter" where inNote:
                alter = Int(Double(value) ?? 0)
            case "octave" where inNote:
                octave = Int(value)
            case "duration" where inNote:
                // <backup>/<forward>의 <duration>은 여기 안 들어온다(inNote가 false다) —
                // 시간을 되감는 표기라 음이 아니다.
                noteDuration = Double(value)
            case "voice" where inNote:
                noteVoice = value
            case "note":
                finishNote()
            default:
                break
            }

            text = ""
        }

        private func resetNoteState() {
            step = nil
            alter = 0
            octave = nil
            noteDuration = nil
            isRest = false
            isChord = false
            isGrace = false
            noteVoice = nil
            tieStop = false
        }

        private func finishNote() {
            defer { inNote = false }
            guard inNote, !parts.isEmpty else { return }

            // 꾸밈음은 <duration>이 없다 — 길이 0짜리 음은 정렬에 잡음만 더한다.
            guard !isGrace, !isRest, let step, let octave else { return }

            let partIndex = parts.count - 1

            // 한 파트 안에 성부가 여럿이면 첫 성부만 쓴다. 반주 성부까지 섞으면 멜로디 순서가 깨진다.
            if let noteVoice {
                if parts[partIndex].firstVoice == nil {
                    parts[partIndex].firstVoice = noteVoice
                } else if parts[partIndex].firstVoice != noteVoice {
                    return
                }
            }

            guard let pitchClass = Self.pitchClass(forStep: step) else { return }
            let midiNote = (octave + 1) * 12 + pitchClass + alter
            let duration = (noteDuration ?? 0) / divisions

            if isChord {
                // 화음에서는 **가장 높은 음만** 남긴다 — 사람이 부르는 멜로디는 보통 화음의 맨 위다.
                // (MusicXML은 화음 안 음의 순서를 규정하지 않아서 "첫 음"으로 고르면 파일마다 답이 다르다.)
                if let last = parts[partIndex].notes.last, midiNote > last.midiNote {
                    parts[partIndex].notes[parts[partIndex].notes.count - 1] =
                        Note(midiNote: midiNote, duration: last.duration)
                }
                return
            }

            // 이음줄로 이어진 음은 한 음이다. 나눠 두면 정렬이 "같은 음을 두 번 불렀다"로 읽어
            // 뒤 음들이 통째로 밀린다.
            if tieStop, let last = parts[partIndex].notes.last, last.midiNote == midiNote {
                parts[partIndex].notes[parts[partIndex].notes.count - 1] =
                    Note(midiNote: midiNote, duration: last.duration + duration)
                return
            }

            parts[partIndex].notes.append(Note(midiNote: midiNote, duration: duration))
        }

        private static func pitchClass(forStep step: String) -> Int? {
            switch step.uppercased() {
            case "C": return 0
            case "D": return 2
            case "E": return 4
            case "F": return 5
            case "G": return 7
            case "A": return 9
            case "B": return 11
            default: return nil
            }
        }
    }

    // MARK: - MIDI 파싱

    /// 화음으로 묶을 온셋 차이(박). MusicXML은 `<chord/>` 태그로 화음을 알려주지만 MIDI에는
    /// 그런 표시가 없어서 **시작 자리가 같으면 화음**으로 본다.
    ///
    /// 사람이 연주해 녹음한 파일은 화음이 정확히 같은 틱에 찍히지 않는다(수십 ms씩 어긋난다).
    /// 그렇다고 넉넉하게 잡으면 빠른 음표를 화음으로 삼켜 멜로디에서 음이 사라진다 — 32분음표가
    /// 0.125박이므로 그보다 한참 작은 값이어야 한다. 0.05박은 흔한 템포(♩=120)에서 25ms다.
    private static let simultaneousOnsetTolerance = 0.05

    /// 트랙에서 읽어낸 음 하나. 화음을 묶고 순서를 잡으려면 시작 자리가 있어야 해서
    /// `Note`(음높이 + 길이)보다 한 단계 앞의 형태를 따로 둔다.
    private struct TimedNote {
        let beat: Double
        let midiNote: Int
        let duration: Double
    }

    static func parseMIDI(_ data: Data) throws -> ImportedScore {
        var sequence: MusicSequence?
        guard NewMusicSequence(&sequence) == noErr, let sequence else { throw ImportError.malformed }
        defer { DisposeMusicSequence(sequence) }

        guard MusicSequenceFileLoadData(sequence, data as CFData, .midiType, MusicSequenceLoadFlags()) == noErr else {
            throw ImportError.malformed
        }

        var trackCount: UInt32 = 0
        guard MusicSequenceGetTrackCount(sequence, &trackCount) == noErr else { throw ImportError.malformed }

        var tracks: [[TimedNote]] = []
        var keySignature: (fifths: Int, mode: KeyDetector.Mode)?

        /// 조표는 **곡 전체의 성질**이라 어느 트랙에서 나왔든 쓴다 — 멜로디가 아니라 반주
        /// 트랙에만 적혀 있는 파일이 흔하고, `MusicSequence`는 포맷에 따라 메타 이벤트를
        /// 템포 트랙으로 옮겨 담기도 한다.
        func collect(_ track: MusicTrack) {
            let contents = readMIDITrack(track)
            if keySignature == nil { keySignature = contents.keySignature }
            if !contents.notes.isEmpty { tracks.append(contents.notes) }
        }

        var tempoTrack: MusicTrack?
        if MusicSequenceGetTempoTrack(sequence, &tempoTrack) == noErr, let tempoTrack {
            collect(tempoTrack)
        }
        for index in 0..<trackCount {
            var track: MusicTrack?
            guard MusicSequenceGetIndTrack(sequence, index, &track) == noErr, let track else { continue }
            collect(track)
        }

        // 반주가 같이 든 파일에서는 멜로디 줄만 필요하다 — MusicXML의 파트 고르기와 같은 규칙.
        guard let melody = tracks.max(by: { averagePitch($0) < averagePitch($1) }) else {
            throw ImportError.noNotesFound
        }

        let notes = collapseChords(melody)
        guard !notes.isEmpty else { throw ImportError.noNotesFound }

        return ImportedScore(notes: notes, keyFifths: keySignature?.fifths, keyMode: keySignature?.mode)
    }

    private static func averagePitch(_ notes: [TimedNote]) -> Double {
        guard !notes.isEmpty else { return -.infinity }
        return Double(notes.map(\.midiNote).reduce(0, +)) / Double(notes.count)
    }

    /// 같은 자리에서 시작하는 음들을 하나로 접고 **가장 높은 음**을 남긴다(멜로디는 보통
    /// 화음의 맨 위). 묶는 기준은 그룹의 **첫 음**이다 — 직전 음과 비교하면 조금씩 어긋난
    /// 음들이 연쇄적으로 한 덩어리가 돼버린다.
    private static func collapseChords(_ notes: [TimedNote]) -> [Note] {
        let ordered = notes.sorted { ($0.beat, $0.midiNote) < ($1.beat, $1.midiNote) }

        var result: [Note] = []
        var groupStart: Double?
        var highest: TimedNote?

        for note in ordered {
            if let start = groupStart, note.beat - start <= simultaneousOnsetTolerance {
                if let current = highest, note.midiNote <= current.midiNote { continue }
                highest = note
            } else {
                if let highest { result.append(Note(midiNote: highest.midiNote, duration: highest.duration)) }
                groupStart = note.beat
                highest = note
            }
        }
        if let highest { result.append(Note(midiNote: highest.midiNote, duration: highest.duration)) }

        return result
    }

    /// 트랙 하나를 훑어 음과 조표를 모은다.
    ///
    /// `MusicSequence`가 note on/off 쌍을 이미 하나의 `MIDINoteMessage`로 합쳐주고, 시간도
    /// 헤더의 division으로 나눠 **박 단위**로 돌려준다 — 4분음표가 1.0이라 우리가 쓰는 단위와
    /// 그대로 맞는다(직접 파싱했다면 가변 길이 수와 running status부터 다뤄야 했다).
    private static func readMIDITrack(_ track: MusicTrack) -> (notes: [TimedNote], keySignature: (fifths: Int, mode: KeyDetector.Mode)?) {
        var iterator: MusicEventIterator?
        guard NewMusicEventIterator(track, &iterator) == noErr, let iterator else { return ([], nil) }
        defer { DisposeMusicEventIterator(iterator) }

        var notes: [TimedNote] = []
        var keySignature: (fifths: Int, mode: KeyDetector.Mode)?

        var hasEvent: DarwinBoolean = false
        MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)

        while hasEvent.boolValue {
            var timestamp: MusicTimeStamp = 0
            var eventType: MusicEventType = 0
            var eventData: UnsafeRawPointer?
            var eventSize: UInt32 = 0

            if MusicEventIteratorGetEventInfo(iterator, &timestamp, &eventType, &eventData, &eventSize) == noErr,
               let eventData {
                switch eventType {
                case kMusicEventType_MIDINoteMessage:
                    let message = eventData.load(as: MIDINoteMessage.self)
                    // 벨로시티 0은 note off를 note on으로 적는 관례라 소리가 나지 않는다.
                    if message.velocity > 0 {
                        notes.append(TimedNote(beat: timestamp,
                                               midiNote: Int(message.note),
                                               duration: Double(message.duration)))
                    }

                case kMusicEventType_Meta:
                    if keySignature == nil, let parsed = parseKeySignature(from: eventData) {
                        keySignature = parsed
                    }

                default:
                    break
                }
            }

            MusicEventIteratorNextEvent(iterator)
            MusicEventIteratorHasCurrentEvent(iterator, &hasEvent)
        }

        return (notes, keySignature)
    }

    /// 조표 메타 이벤트(0x59)만 꺼낸다. 페이로드는 두 바이트 — 5도권 개수(플랫이 음수인
    /// signed byte)와 장/단조 표시다.
    private static func parseKeySignature(from eventData: UnsafeRawPointer) -> (fifths: Int, mode: KeyDetector.Mode)? {
        let event = eventData.assumingMemoryBound(to: MIDIMetaEvent.self)
        guard event.pointee.metaEventType == 0x59, event.pointee.dataLength >= 2 else { return nil }

        // `data`는 C의 가변 길이 배열(`UInt8 data[1]`)이라 Swift에서 첨자로 못 읽는다 —
        // 구조체 안에서 그 필드가 시작하는 자리를 구해 raw 포인터로 읽는다.
        let payloadOffset = MemoryLayout<MIDIMetaEvent>.offset(of: \.data) ?? 8
        let payload = eventData.advanced(by: payloadOffset).assumingMemoryBound(to: UInt8.self)

        return (fifths: Int(Int8(bitPattern: payload[0])),
                mode: payload[1] == 1 ? .minor : .major)
    }

}
