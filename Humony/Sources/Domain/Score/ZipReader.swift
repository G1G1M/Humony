import Compression
import Foundation

/// zip 아카이브에서 파일 하나를 꺼낸다 — 압축 MusicXML(`.mxl`)을 읽기 위해서다 (157절).
///
/// **왜 직접 만드는가**: iOS에 공개된 zip API가 없다. 서드파티를 붙이는 건 `CLAUDE.md`의
/// "직접 구현"(학습 목적) 원칙과 어긋나고, 압축 해제 자체는 `Compression` 프레임워크가
/// 해주므로 남는 일은 **zip이 파일 목록을 어디에 어떻게 적어두는지 읽는 것**뿐이다.
///
/// zip은 파일 끝에 목차(중앙 디렉터리)를 둔다. 각 파일 앞에도 머리말이 있지만 거기엔 크기가
/// 안 적혀 있을 수 있어서(스트리밍으로 만든 경우), 목차를 읽는 쪽이 정확하다.
enum ZipReader {

    struct Entry {
        let name: String
        let data: Data
    }

    enum ZipError: Error, Equatable {
        case notAZipArchive
        case corrupted
    }

    /// 조건에 맞는 **첫 파일**을 꺼낸다. 목차 순서대로 본다.
    static func firstEntry(in archive: Data, where matches: (String) -> Bool) throws -> Entry {
        for header in try centralDirectory(of: archive) where matches(header.name) {
            return Entry(name: header.name, data: try extract(header, from: archive))
        }
        throw ZipError.corrupted
    }

    // MARK: - 목차 읽기

    private struct CentralHeader {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4b50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50

    private static func centralDirectory(of archive: Data) throws -> [CentralHeader] {
        // 목차의 끝 표시는 파일 맨 뒤에 있다(뒤에 주석이 붙을 수 있어 뒤에서부터 찾는다).
        guard archive.count >= 22 else { throw ZipError.notAZipArchive }
        var eocd: Int?
        var offset = archive.count - 22
        let lowestPossible = max(0, archive.count - 22 - 65_535)
        while offset >= lowestPossible {
            if readUInt32(archive, at: offset) == endOfCentralDirectorySignature {
                eocd = offset
                break
            }
            offset -= 1
        }
        guard let eocd else { throw ZipError.notAZipArchive }

        let entryCount = Int(readUInt16(archive, at: eocd + 10))
        var cursor = Int(readUInt32(archive, at: eocd + 16))

        var headers: [CentralHeader] = []
        for _ in 0..<entryCount {
            guard cursor + 46 <= archive.count,
                  readUInt32(archive, at: cursor) == centralFileHeaderSignature else {
                throw ZipError.corrupted
            }

            let nameLength = Int(readUInt16(archive, at: cursor + 28))
            let extraLength = Int(readUInt16(archive, at: cursor + 30))
            let commentLength = Int(readUInt16(archive, at: cursor + 32))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= archive.count else { throw ZipError.corrupted }

            let name = String(decoding: archive[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            headers.append(CentralHeader(
                name: name,
                compressionMethod: readUInt16(archive, at: cursor + 10),
                compressedSize: Int(readUInt32(archive, at: cursor + 20)),
                uncompressedSize: Int(readUInt32(archive, at: cursor + 24)),
                localHeaderOffset: Int(readUInt32(archive, at: cursor + 42))
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return headers
    }

    // MARK: - 꺼내기

    private static func extract(_ header: CentralHeader, from archive: Data) throws -> Data {
        let local = header.localHeaderOffset
        guard local + 30 <= archive.count,
              readUInt32(archive, at: local) == localFileHeaderSignature else {
            throw ZipError.corrupted
        }

        // 파일 앞 머리말의 이름·부가정보 길이는 목차의 것과 다를 수 있어서 여기서 다시 읽는다.
        let nameLength = Int(readUInt16(archive, at: local + 26))
        let extraLength = Int(readUInt16(archive, at: local + 28))
        let start = local + 30 + nameLength + extraLength
        let end = start + header.compressedSize
        guard start <= end, end <= archive.count else { throw ZipError.corrupted }

        let payload = archive[start..<end]

        switch header.compressionMethod {
        case 0:
            return Data(payload)          // 압축 없이 그대로 담긴 경우
        case 8:
            return try inflate(Data(payload), expectedSize: header.uncompressedSize)
        default:
            throw ZipError.corrupted      // zip이 쓸 수 있는 다른 방식들은 실제 .mxl에 안 나온다
        }
    }

    /// zip이 쓰는 건 헤더 없는 raw DEFLATE다 — 애플의 `COMPRESSION_ZLIB`가 정확히 그것을 다룬다.
    private static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }

        var output = Data(count: expectedSize)
        let written: Int = output.withUnsafeMutableBytes { outputBuffer -> Int in
            guard let destination = outputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { inputBuffer -> Int in
                guard let source = inputBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destination, expectedSize,
                                                 source, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }

        guard written > 0 else { throw ZipError.corrupted }
        return output.prefix(written)
    }

    // MARK: - 바이트 읽기 (zip은 전부 리틀 엔디안이다)

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
    }
}
