import AudioToolbox
import Darwin
import Foundation

/// Lossless removal of the `free` padding earlier encoders left between `moov`
/// and `mdat` (compact-library-storage D5). Only the expected layout
/// `ftyp`, `moov`, `free`…, `mdat` is rewritten; the audio bytes are copied
/// unchanged and every chunk offset is moved by the removed length.
public enum AudioChunkCompactor {
    /// Padding below this is left in place.
    public static let minimumSaving = 4096

    public struct Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        public let reason: String
        public init(reason: String) { self.reason = reason }
        public var description: String { "Chunk not compactable: \(reason)" }
    }

    /// The same file without padding, or nil when there is less than
    /// `minimumSaving` to remove. Throws `Refusal` for any other layout.
    public static func compacted(_ data: Data) throws -> Data? {
        let bytes = [UInt8](data)
        let top = try boxes(bytes, from: 0, to: bytes.count)
        guard top.count >= 3, top[0].type == "ftyp", top[1].type == "moov", top.last!.type == "mdat",
              top[2..<(top.count - 1)].allSatisfy({ $0.type == "free" }) else {
            throw Refusal(reason: "layout \(top.map(\.type))")
        }
        let moov = top[1], mdat = top.last!
        let removed = top[2..<(top.count - 1)].reduce(0) { $0 + $1.size }
        guard removed >= minimumSaving else { return nil }
        // The audio payload, before and after.
        let payload = (mdat.offset + 8)..<(mdat.offset + mdat.size)
        let newMdat = mdat.offset - removed
        var output = Array(bytes[0..<(moov.offset + moov.size)])
        var tables = 0
        try patchOffsets(&output, in: moov.offset + 8, to: moov.offset + moov.size, path: ["moov"]) { old in
            guard payload.contains(old) else { throw Refusal(reason: "chunk offset \(old) outside mdat") }
            let new = old - removed
            guard new >= newMdat + 8 else { throw Refusal(reason: "chunk offset underflow") }
            return new
        } tables: { tables += 1 }
        guard tables > 0 else { throw Refusal(reason: "no chunk offset table") }
        output += bytes[mdat.offset..<(mdat.offset + mdat.size)]
        return Data(output)
    }

    /// `free` padding announced by the box headers within `head`, the first
    /// bytes of a file; enough to skip a chunk without reading all of it.
    public static func paddingInHead(_ head: Data) -> Int {
        let bytes = [UInt8](head)
        var offset = 0, padding = 0
        while offset + 8 <= bytes.count {
            let size = Int(bytes[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard size >= 8 else { break }
            if bytes[(offset + 4)..<(offset + 8)].elementsEqual("free".utf8) { padding += size }
            offset += size
        }
        return padding
    }

    /// Bytes of `free` padding a compaction would remove, without checking the
    /// rest of the layout (reports).
    public static func padding(_ data: Data) -> Int {
        let bytes = [UInt8](data)
        return ((try? boxes(bytes, from: 0, to: bytes.count)) ?? []).filter { $0.type == "free" }.reduce(0) { $0 + $1.size }
    }

    /// Checks through AudioToolbox that two files hold the same audio: data
    /// format, magic cookie, packet table, packet count and every packet's
    /// bytes and description.
    public static func verifySamePackets(original: Int32, compacted: Int32) throws {
        let a = try PacketReader(original), b = try PacketReader(compacted)
        guard a.format == b.format else { throw Refusal(reason: "data format differs") }
        guard a.cookie == b.cookie else { throw Refusal(reason: "magic cookie differs") }
        guard a.table == b.table else { throw Refusal(reason: "packet table differs") }
        guard a.packets == b.packets, a.packets > 0 else { throw Refusal(reason: "packet count differs") }
        var start: Int64 = 0
        while start < Int64(a.packets) {
            let count = UInt32(min(Int64(64), Int64(a.packets) - start))
            let left = try a.read(start, count), right = try b.read(start, count)
            guard left.data == right.data, left.descriptions == right.descriptions else {
                throw Refusal(reason: "packet \(start) differs")
            }
            start += Int64(count)
        }
    }

    // MARK: Boxes

    struct Box { let type: String; let offset: Int; let size: Int }

    static func boxes(_ bytes: [UInt8], from start: Int, to end: Int) throws -> [Box] {
        var result: [Box] = [], offset = start
        while offset < end {
            guard end - offset >= 8 else { throw Refusal(reason: "truncated box header") }
            let size = Int(be32(bytes, offset))
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            // 64-bit (1) and to-end (0) sizes are not written by our encoders.
            guard size >= 8, size <= end - offset else { throw Refusal(reason: "box \(type) size \(size)") }
            result.append(Box(type: type, offset: offset, size: size))
            offset += size
        }
        return result
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "udta"]

    private static func patchOffsets(_ bytes: inout [UInt8], in start: Int, to end: Int, path: [String],
                                     move: (Int) throws -> Int, tables: () -> Void) throws {
        for box in try boxes(bytes, from: start, to: end) {
            let body = box.offset + 8, boxEnd = box.offset + box.size
            switch box.type {
            case "stco", "co64":
                guard path.last == "stbl", box.size >= 16 else { throw Refusal(reason: "misplaced \(box.type)") }
                let width = box.type == "stco" ? 4 : 8
                let count = Int(be32(bytes, body + 4))
                guard box.size == 16 + width * count else { throw Refusal(reason: "\(box.type) size") }
                for index in 0..<count {
                    let at = body + 8 + width * index
                    if width == 4 {
                        let new = try move(Int(be32(bytes, at)))
                        guard new <= Int(UInt32.max) else { throw Refusal(reason: "stco overflow") }
                        put(&bytes, at, UInt64(new), width: 4)
                    } else {
                        let old = be64(bytes, at)
                        guard old <= UInt64(Int.max) else { throw Refusal(reason: "co64 overflow") }
                        put(&bytes, at, UInt64(try move(Int(old))), width: 8)
                    }
                }
                tables()
            case "saio", "iloc":
                // Other absolute offsets this rewrite does not move.
                throw Refusal(reason: "\(box.type) box")
            case _ where containers.contains(box.type):
                try patchOffsets(&bytes, in: body, to: boxEnd, path: path + [box.type], move: move, tables: tables)
            default:
                continue
            }
        }
    }

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        bytes[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
    private static func be64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        bytes[at..<(at + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
    private static func put(_ bytes: inout [UInt8], _ at: Int, _ value: UInt64, width: Int) {
        for index in 0..<width { bytes[at + index] = UInt8(truncatingIfNeeded: value >> UInt64(8 * (width - 1 - index))) }
    }
}

/// Packet access to an M4A through the descriptor callbacks.
private final class PacketReader {
    private let io: AudioDescriptorIO
    private var file: AudioFileID?
    let format: Data, cookie: Data, table: Data
    let packets: UInt64
    private let maximumPacket: UInt32

    init(_ fd: Int32) throws {
        io = AudioDescriptorIO(fd)
        try encodingCheck(AudioFileOpenWithCallbacks(io.pointer, descriptorRead, nil, descriptorSize, nil,
                                                     kAudioFileM4AType, &file), "Read AAC container")
        guard let opened = file else { throw AudioChunkCompactor.Refusal(reason: "no container") }
        func property(_ id: AudioFilePropertyID) throws -> Data { try Self.property(opened, id) }
        do {
            format = try property(kAudioFilePropertyDataFormat)
            cookie = (try? property(kAudioFilePropertyMagicCookieData)) ?? Data()
            table = try property(kAudioFilePropertyPacketTableInfo)
            packets = try property(kAudioFilePropertyAudioDataPacketCount).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
            maximumPacket = try property(kAudioFilePropertyMaximumPacketSize).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        } catch { AudioFileClose(opened); file = nil; throw error }
    }

    deinit { if let file { AudioFileClose(file) } }

    private static func property(_ file: AudioFileID, _ id: AudioFilePropertyID) throws -> Data {
        var size: UInt32 = 0, writable: UInt32 = 0
        try encodingCheck(AudioFileGetPropertyInfo(file, id, &size, &writable), "Read AAC property")
        var data = Data(count: Int(size))
        try data.withUnsafeMutableBytes { try encodingCheck(AudioFileGetProperty(file, id, &size, $0.baseAddress!), "Read AAC property") }
        return data.prefix(Int(size))
    }

    func read(_ start: Int64, _ count: UInt32) throws -> (data: Data, descriptions: [Int64]) {
        var packets = count
        var bytes = UInt32(max(maximumPacket, 1)) * count
        var data = Data(count: Int(bytes))
        var descriptions = [AudioStreamPacketDescription](repeating: .init(), count: Int(count))
        try data.withUnsafeMutableBytes { buffer in
            try encodingCheck(AudioFileReadPacketData(file!, false, &bytes, &descriptions, start, &packets, buffer.baseAddress!),
                              "Read AAC packets")
        }
        guard packets == count else { throw AudioChunkCompactor.Refusal(reason: "short packet read") }
        return (data.prefix(Int(bytes)), descriptions.prefix(Int(packets)).flatMap {
            [$0.mStartOffset, Int64($0.mDataByteSize), Int64($0.mVariableFramesInPacket)]
        })
    }
}
