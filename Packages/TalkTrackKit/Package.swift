// swift-tools-version: 6.3
import Foundation
import PackageDescription

/// Storage and audio fixture programs are local developer tools; a public
/// checkout does not contain them.
let fixtures = ["TalkTrackStorageFixture", "TalkTrackAudioStorageFixture"].filter {
    FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Sources/\($0)").path)
}

let package = Package(
    name: "TalkTrackKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TalkTrackAudio", targets: ["TalkTrackAudio"]),
        .library(name: "TalkTrackDomain", targets: ["TalkTrackDomain"]),
        .library(name: "TalkTrackServices", targets: ["TalkTrackServices"]),
    ] + fixtures.map { .executable(name: $0, targets: [$0]) },
    targets: [
        .target(name: "TalkTrackAudio"),
        .target(name: "TalkTrackDomain"),
        .target(name: "TalkTrackServices", dependencies: ["TalkTrackDomain", "TalkTrackAudio"], resources: [.process("Resources")]),
        .testTarget(name: "TalkTrackDomainTests", dependencies: ["TalkTrackDomain"]),
        .testTarget(name: "TalkTrackAudioTests", dependencies: ["TalkTrackAudio"]),
        .testTarget(name: "TalkTrackServicesTests", dependencies: ["TalkTrackServices", "TalkTrackDomain"]),
    ] + fixtures.map { .executableTarget(name: $0, dependencies: ["TalkTrackServices", "TalkTrackDomain", "TalkTrackAudio"]) }
)
