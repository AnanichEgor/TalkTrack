import Foundation
import Testing
@testable import TalkTrackServices

/// Real disk images (task 10.4): another volume, a full volume, a volume
/// detached during the copy, and a renamed library folder. They attach and
/// detach images with hdiutil, so they run only from
/// `scripts/test-library-migration.sh` (TALKTRACK_VOLUME_FIXTURES=1).
private struct DiskImage {
    let image: URL, mount: URL

    init(_ folder: URL, name: String, megabytes: Int) throws {
        image = folder.appendingPathComponent("\(name).dmg")
        mount = folder.appendingPathComponent("\(name)-volume", isDirectory: true)
        try Self.run(["create", "-size", "\(megabytes)m", "-fs", "APFS", "-volname", name, "-type", "UDIF", image.path])
        try attach()
    }

    func attach() throws {
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try Self.run(["attach", "-nobrowse", "-mountpoint", mount.path, image.path])
    }

    func detach() throws { try Self.run(["detach", "-force", mount.path]) }

    @discardableResult static func run(_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw LibraryMigrationError.destinationUnavailable("hdiutil \(arguments.first ?? ""): \(output)") }
        return output
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TALKTRACK_VOLUME_FIXTURES"] == "1"))
struct LibraryMigrationVolumeTests {
    @Test func movesToAnotherVolumeAndBack() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        let volume = try DiskImage(fixture.base.url, name: "TTMove", megabytes: 200)
        defer { try? volume.detach() }
        let destination = volume.mount.appendingPathComponent("Meetings Library", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let migrator = LibraryMigrator(locations: fixture.locations, modelsRoot: fixture.support.appendingPathComponent("Models"))
        let plan = try await migrator.plan(source: fixture.library, destination: destination, recording: false)
        #expect(plan.availableBytes.map { $0 > plan.requiredBytes } == true)
        _ = try await migrator.migrate(source: fixture.library, destination: destination)
        #expect(try MoveFixture.hashes(destination.appendingPathComponent(OwnedLibrary.directoryName)) == fixture.original)
        #expect(try fixture.listing(fixture.source) == ["prompt.md", "src"])
        #expect(try await fixture.authoritativeNotes().1 == "Заметки остаются")
        let moved = try await OwnedLibrary().resume(try #require(try fixture.locations.load()))
        _ = try await migrator.migrate(source: moved, destination: fixture.source)
        #expect(try MoveFixture.hashes(fixture.sourceOwned) == fixture.original)
        #expect(try fixture.listing(destination).isEmpty)
        #expect(try fixture.unrelatedUnchanged())
    }

    @Test func fullVolumeIsRefusedAndAnActualOutOfSpaceKeepsTheSource() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        // A library larger than the volume.
        var big = Data(count: 40 << 20)
        big.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        try big.write(to: fixture.sourceOwned.appendingPathComponent("Meetings/\(fixture.meetingID)/big.m4a"))
        let original = try MoveFixture.hashes(fixture.sourceOwned)
        let volume = try DiskImage(fixture.base.url, name: "TTSmall", megabytes: 24)
        defer { try? volume.detach() }
        let checked = LibraryMigrator(locations: fixture.locations, modelsRoot: fixture.support.appendingPathComponent("Models"))
        await #expect(throws: LibraryMigrationError.self) {
            try await checked.plan(source: fixture.library, destination: volume.mount, recording: false)
        }
        // Claim enough space so the copy itself runs out (ENOSPC).
        let unchecked = fixture.migrator()
        await #expect(throws: LibraryError.self) {
            _ = try await unchecked.migrate(source: fixture.library, destination: volume.mount)
        }
        #expect(try MoveFixture.hashes(fixture.sourceOwned) == original)
        #expect(try fixture.listing(volume.mount).filter { !$0.hasPrefix(".") || $0.hasPrefix(".talktrack") }.isEmpty)
        #expect(try fixture.locations.load() == nil)
        #expect(try await fixture.migrator().journals().isEmpty)
    }

    @Test func detachedVolumeKeepsTheSourceAndItsCopyIsRemovedOnReconnect() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        let volume = try DiskImage(fixture.base.url, name: "TTDetach", megabytes: 100)
        defer { try? volume.detach() }
        let migrator = fixture.migrator { step in
            if case .copied(let index) = step, index >= 8 { try volume.detach() }
        }
        await #expect(throws: (any Error).self) {
            _ = try await migrator.migrate(source: fixture.library, destination: volume.mount)
        }
        #expect(try MoveFixture.hashes(fixture.sourceOwned) == fixture.original)
        #expect(try fixture.locations.load() == nil)
        #expect(try await fixture.migrator().recover() == [.destinationUnavailable(LibraryMigrator.path(volume.mount))])
        #expect(try await fixture.authoritativeNotes().0 == fixture.source.resolvingSymlinksInPath())
        try volume.attach()
        #expect(try await fixture.migrator().recover() == [.discarded(source: LibraryMigrator.path(fixture.source))])
        #expect(try fixture.listing(volume.mount).filter { $0.hasPrefix(".talktrack") }.isEmpty)
        #expect(try fixture.unrelatedUnchanged())
    }

    @Test func renamedFolderRenewsTheBookmarkAndAnUnmountedOneIsUnavailable() async throws {
        let fixture = try await MoveFixture()
        defer { fixture.base.remove() }
        let volume = try DiskImage(fixture.base.url, name: "TTStale", megabytes: 100)
        defer { try? volume.detach() }
        let destination = volume.mount.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let outcome = try await fixture.migrator().migrate(source: fixture.library, destination: destination)
        let renamed = volume.mount.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: destination, to: renamed)
        let reopened = try await OwnedLibrary().resume(outcome.location)
        #expect(reopened.bookmarkWasStale)
        #expect(reopened.root.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
        let renewed = try reopened.makeLocation()
        try volume.detach()
        await #expect(throws: LibraryError.self) { _ = try await OwnedLibrary().resume(renewed) }
        try volume.attach()
        let again = try await OwnedLibrary().resume(renewed)
        #expect(!again.bookmarkWasStale)
        #expect(again.manifest.libraryID == fixture.library.manifest.libraryID)
    }
}
