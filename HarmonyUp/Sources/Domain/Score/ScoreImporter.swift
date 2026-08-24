import Foundation

/// 악보 파일을 읽어 "정답지"로 쓸 음 목록과 조표를 뽑는다 (155절).
///
/// **왜 악보를 받는가**: 지금까지 채보 오류는 전부 "오디오만 보고 무슨 음인지 알아내야 한다"는
/// 근본 난이도에서 나왔다(149절 A#3 오탐, 152절 조성이 반음 위로 번짐, 153절 떨림이 독립
/// 음표가 돼 화음이 반음 튐). 부를 곡의 악보가 있으면 문제가 **인식에서 정렬로** 바뀐다 —
/// "이게 무슨 음이지?"가 아니라 "이 음이 악보의 어느 음이지?"다.
///
/// **서드파티를 안 쓴다**: MusicXML은 XML이라 `XMLParser`로 충분하다. `CLAUDE.md`의
/// "피치 검출 라이브러리 금지(학습 목적)" 규칙과 부딪히지 않고, 124절 WORLD 때 했던
/// 라이선스 검토도 필요 없다.
///
/// **길이는 초가 아니라 4분음표 = 1.0인 상대값이다.** 교정은 음높이만 악보로 스냅하고
/// 타이밍은 부른 그대로 두기 때문에(실제로 부른 리듬이 화음 타이밍의 기준이다) 악보의
/// 템포는 필요 없다. 이 길이는 조성 판별의 가중치로만 쓰인다.
enum ScoreImporter {

    struct Note: Equatable {
        let midiNote: Int
        /// 4분음표 = 1.0인 상대 길이.
        let duration: Double
    }

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

    static func load(from url: URL) throws -> ImportedScore {
        let fileExtension = url.pathExtension.lowercased()
        guard musicXMLExtensions.contains(fileExtension) else { throw ImportError.unsupportedFileType }

        guard let data = try? Data(contentsOf: url) else { throw ImportError.malformed }
        return try parseMusicXML(data)
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
}
