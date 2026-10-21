import Foundation
import Testing
@testable import TalkTrackServices

@Suite struct ClipboardSnapshotTests {
    private func item(_ bytes: Int, types: Int = 1) -> [(type: String, data: Data)] {
        (0..<types).map { ("public.data.\($0)", Data(count: bytes)) }
    }

    @Test func bounds() {
        #expect(ClipboardSnapshot(items: [item(ClipboardSnapshot.maximumBytes)]) != nil)
        #expect(ClipboardSnapshot(items: [item(ClipboardSnapshot.maximumBytes / 2), item(ClipboardSnapshot.maximumBytes / 2 + 1)]) == nil)
        #expect(ClipboardSnapshot(items: [item(1, types: 128), item(1, types: 128)]) != nil)
        #expect(ClipboardSnapshot(items: [item(1, types: 128), item(1, types: 129)]) == nil)
        #expect(ClipboardSnapshot(items: []) != nil)
    }

    @Test func restorableOnlyWhileDictatedTextRemains() {
        let start = ContinuousClock.now
        var snapshot = ClipboardSnapshot(items: [item(10)], taken: start)!
        // Not offered before the dictated text was written.
        #expect(!snapshot.isRestorable(changeCount: 7, now: start))
        snapshot.dictatedTextWritten(changeCount: 7)
        #expect(snapshot.isRestorable(changeCount: 7, now: start + .seconds(299)))
        // The user copied something else.
        #expect(!snapshot.isRestorable(changeCount: 8, now: start + .seconds(10)))
        #expect(snapshot.isStale(changeCount: 8, now: start + .seconds(10)))
    }

    @Test func expiresAfterFiveMinutes() {
        let start = ContinuousClock.now
        var snapshot = ClipboardSnapshot(items: [item(10)], taken: start)!
        snapshot.dictatedTextWritten(changeCount: 3)
        #expect(!snapshot.isRestorable(changeCount: 3, now: start + .seconds(300)))
        #expect(snapshot.isStale(changeCount: 3, now: start + .seconds(301)))
    }
}
