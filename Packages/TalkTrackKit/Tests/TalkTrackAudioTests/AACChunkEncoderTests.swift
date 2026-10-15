import Darwin
import Foundation
import Testing
@testable import TalkTrackAudio

@Suite struct AACChunkEncoderTests {
    @Test(arguments: [1, 1023, 1024, 1025, 479_999, 480_000])
    func exactValidFramesAfterNativeTrimming(count: Int) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("audio.m4a").path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        #expect(fd >= 0)
        defer { close(fd) }
        let encoder = try AACChunkEncoder(fileDescriptor: fd)
        let input = (0..<count).map { Float(0.3 * sin(Double($0) * 2 * .pi * 440 / 48_000)) }
        try encoder.append(input[...])
        let info = try encoder.finish()
        #expect(info.validFrames == UInt64(count))
        #expect(info.primingFrames > 0)
        #expect(info.packetCount * 1024 == info.validFrames + UInt64(info.primingFrames) + UInt64(info.remainderFrames))
        var total = 0
        _ = try AACChunkEncoder.decode(fileDescriptor: fd, expectedFrames: UInt64(count)) { total += $0.count }
        #expect(total == count)
        #expect(throws: AudioEncodingError.self) { try encoder.append([Float(0.1)][...]) }
    }

    @Test func rejectsNonfiniteSamplesAndExcessFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fd = open(url.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        defer { close(fd); try? FileManager.default.removeItem(at: url) }
        let encoder = try AACChunkEncoder(fileDescriptor: fd)
        #expect(throws: AudioEncodingError.self) { try encoder.append([Float.nan][...]) }
        #expect(throws: AudioEncodingError.self) { try encoder.append([Float](repeating: 0, count: 480_001)[...]) }
        #expect(encoder.frames == 0)
        encoder.abort()
    }
}
