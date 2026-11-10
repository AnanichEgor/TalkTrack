import Darwin
import Foundation
import Testing
@testable import TalkTrackAudio

@Suite struct AudioChunkCompactorTests {
    /// A chunk in the earlier layout (large `free` box), like stored libraries hold.
    static func paddedChunk(_ folder: URL, frames: Int = 480_000) throws -> (path: String, info: AACPacketInfo) {
        var generator = SystemRandomNumberGenerator()
        let input = (0..<frames).map { Float(0.3 * sin(Double($0) * 0.05)) + Float.random(in: -0.05...0.05, using: &generator) }
        let path = folder.appendingPathComponent("\(UUID().uuidString).m4a").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        defer { close(fd) }
        let encoder = try AACChunkEncoder(fileDescriptor: fd, reservesDuration: false)
        try encoder.append(input[...])
        return (path, try encoder.finish())
    }

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func write(_ data: Data, _ folder: URL) throws -> String {
        let path = folder.appendingPathComponent("\(UUID().uuidString).m4a").path
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    static func decoded(_ path: String, _ frames: UInt64) throws -> (samples: [Float], info: AACPacketInfo) {
        let fd = open(path, O_RDONLY)
        defer { close(fd) }
        var samples: [Float] = []
        let info = try AACChunkEncoder.decode(fileDescriptor: fd, expectedFrames: frames) { samples.append(contentsOf: $0) }
        return (samples, info)
    }

    static func verify(_ a: String, _ b: String) throws {
        let left = open(a, O_RDONLY), right = open(b, O_RDONLY)
        defer { close(left); close(right) }
        try AudioChunkCompactor.verifySamePackets(original: left, compacted: right)
    }

    @Test(arguments: [480_000, 1, 1025, 200_000])
    func paddingIsRemovedLosslessly(frames: Int) throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (path, info) = try Self.paddedChunk(folder, frames: frames)
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let padding = AudioChunkCompactor.padding(original)
        #expect(padding > 32_768)
        let compacted = try #require(try AudioChunkCompactor.compacted(original))
        #expect(compacted.count == original.count - padding)
        #expect(try AACChunkEncoderTests.boxes(compacted).map(\.0) == ["ftyp", "moov", "mdat"])
        let out = try Self.write(compacted, folder)
        try Self.verify(path, out)
        let before = try Self.decoded(path, info.validFrames), after = try Self.decoded(out, info.validFrames)
        #expect(after.info == info)
        // Bit-identical PCM, not just close.
        #expect(before.samples.map(\.bitPattern) == after.samples.map(\.bitPattern))
        // Idempotent: nothing left to remove.
        #expect(try AudioChunkCompactor.compacted(compacted) == nil)
    }

    @Test func currentEncoderOutputIsLeftAlone() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("chunk.m4a").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        let encoder = try AACChunkEncoder(fileDescriptor: fd)
        try encoder.append([Float](repeating: 0.1, count: 480_000)[...])
        _ = try encoder.finish()
        close(fd)
        #expect(try AudioChunkCompactor.compacted(Data(contentsOf: URL(fileURLWithPath: path))) == nil)
    }

    @Test func co64OffsetsAreMovedToo() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (path, info) = try Self.paddedChunk(folder)
        let wide = try Self.withCo64(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(Self.types(wide).contains("co64"))
        let widePath = try Self.write(wide, folder)
        try Self.verify(path, widePath)
        let compacted = try #require(try AudioChunkCompactor.compacted(wide))
        #expect(Self.types(compacted).contains("co64"))
        let out = try Self.write(compacted, folder)
        try Self.verify(path, out)
        #expect(try Self.decoded(out, info.validFrames).info == info)
    }

    @Test func unexpectedLayoutsAreRefused() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.paddedChunk(folder).path))
        let top = try AudioChunkCompactor.boxes([UInt8](data), from: 0, to: data.count)
        func slice(_ box: AudioChunkCompactor.Box) -> Data { data.subdata(in: box.offset..<(box.offset + box.size)) }
        let ftyp = slice(top[0]), moov = slice(top[1]), free = slice(top[2]), mdat = slice(top.last!)
        func refused(_ candidate: Data) -> Bool {
            do { _ = try AudioChunkCompactor.compacted(candidate); return false } catch { return error is AudioChunkCompactor.Refusal }
        }
        // `free` before `moov`.
        #expect(refused(ftyp + free + moov + mdat))
        // A box after `mdat`.
        #expect(refused(ftyp + moov + free + mdat + Self.box("udta", Data(count: 8))))
        // An unknown top-level box.
        #expect(refused(ftyp + moov + Self.box("wide", Data()) + free + mdat))
        // A 64-bit `mdat` size.
        var large = Data([0, 0, 0, 1]) + Data("mdat".utf8)
        withUnsafeBytes(of: UInt64(mdat.count + 8).bigEndian) { large.append(contentsOf: $0) }
        #expect(refused(ftyp + moov + free + large + mdat.dropFirst(8)))
        // Truncated file.
        #expect(refused((ftyp + moov + free + mdat).dropLast(10)))
        // A chunk offset outside `mdat`.
        var broken = [UInt8](ftyp + moov + free + mdat)
        let stco = try #require(Self.find("stco", in: broken, from: ftyp.count + 8, to: ftyp.count + moov.count))
        broken[stco + 16] = 0; broken[stco + 17] = 0; broken[stco + 18] = 0; broken[stco + 19] = 4
        #expect(refused(Data(broken)))
        // Not even a container.
        #expect(refused(Data(repeating: 0xAB, count: 9000)))
    }

    @Test func aChangedPacketFailsVerification() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (path, _) = try Self.paddedChunk(folder)
        var data = try #require(try AudioChunkCompactor.compacted(Data(contentsOf: URL(fileURLWithPath: path))))
        data[data.count - 100] ^= 0xFF
        let out = try Self.write(data, folder)
        #expect(throws: AudioChunkCompactor.Refusal.self) { try Self.verify(path, out) }
    }

    // MARK: Helpers

    static func box(_ type: String, _ body: Data) -> Data {
        var data = Data()
        withUnsafeBytes(of: UInt32(body.count + 8).bigEndian) { data.append(contentsOf: $0) }
        return data + Data(type.utf8) + body
    }

    static func types(_ data: Data) -> [String] {
        var result: [String] = []
        func walk(_ start: Int, _ end: Int) {
            for box in (try? AudioChunkCompactor.boxes([UInt8](data), from: start, to: end)) ?? [] {
                result.append(box.type)
                if ["moov", "trak", "mdia", "minf", "stbl"].contains(box.type) { walk(box.offset + 8, box.offset + box.size) }
            }
        }
        walk(0, data.count)
        return result
    }

    static func find(_ type: String, in bytes: [UInt8], from start: Int, to end: Int) -> Int? {
        for box in (try? AudioChunkCompactor.boxes(bytes, from: start, to: end)) ?? [] {
            if box.type == type { return box.offset }
            if ["moov", "trak", "mdia", "minf", "stbl"].contains(box.type),
               let found = find(type, in: bytes, from: box.offset + 8, to: box.offset + box.size) { return found }
        }
        return nil
    }

    /// Rewrites `stco` as `co64` and shrinks the `free` box by the growth, so
    /// `mdat` and every offset stay where they were.
    static func withCo64(_ data: Data) throws -> Data {
        func rebuild(_ box: AudioChunkCompactor.Box) throws -> Data {
            let body = data.subdata(in: (box.offset + 8)..<(box.offset + box.size))
            switch box.type {
            case "stco":
                let count = Int(body[body.startIndex + 4..<body.startIndex + 8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                var out = body.prefix(8)
                for index in 0..<count {
                    let at = body.startIndex + 8 + 4 * index
                    let value = body[at..<(at + 4)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    withUnsafeBytes(of: value.bigEndian) { out.append(contentsOf: $0) }
                }
                return Self.box("co64", out)
            case "moov", "trak", "mdia", "minf", "stbl":
                let children = try AudioChunkCompactor.boxes([UInt8](data), from: box.offset + 8, to: box.offset + box.size)
                return Self.box(box.type, try children.reduce(Data()) { $0 + (try rebuild($1)) })
            default:
                return data.subdata(in: box.offset..<(box.offset + box.size))
            }
        }
        let top = try AudioChunkCompactor.boxes([UInt8](data), from: 0, to: data.count)
        let moov = try rebuild(top[1])
        let growth = moov.count - top[1].size
        let free = box("free", Data(count: top[2].size - 8 - growth))
        return data.subdata(in: 0..<top[0].size) + moov + free + data.subdata(in: top.last!.offset..<data.count)
    }
}
