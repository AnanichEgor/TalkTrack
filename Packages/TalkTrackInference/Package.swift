// swift-tools-version: 6.3
import PackageDescription

// Deliberately use Tokenizers, never the Transformers umbrella (CoreML).
// Vendored audio/speaker revisions and modifications: ThirdParty/source-provenance.json.
let package = Package(
    name: "TalkTrackInference",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TalkTrackInferenceRuntime", targets: ["TalkTrackInferenceRuntime"]),
        .library(name: "TalkTrackTextMLX", targets: ["TalkTrackTextMLX"]),
        .library(name: "MLXAudioSTT", targets: ["MLXAudioSTT"]),
        .library(name: "TalkTrackSpeakerMLX", targets: ["TalkTrackSpeakerMLX"]),
    ],
    dependencies: [
        .package(path: "../TalkTrackKit"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.4"),
    ],
    targets: [
        .target(name: "TalkTrackInferenceRuntime", dependencies: [
            "MLXAudioSTT", "TalkTrackSpeakerMLX", "TalkTrackTextMLX",
            .product(name: "TalkTrackDomain", package: "TalkTrackKit"),
            .product(name: "TalkTrackServices", package: "TalkTrackKit"),
        ]),
        .target(name: "TalkTrackTextMLX", dependencies: [
            .product(name: "TalkTrackDomain", package: "TalkTrackKit"),
            .product(name: "TalkTrackServices", package: "TalkTrackKit"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "Hub", package: "swift-transformers"),
        ]),
        .target(name: "MLXAudioCore", dependencies: [.product(name: "MLX", package: "mlx-swift")]),
        .target(name: "MLXAudioSTT", dependencies: [
            .product(name: "TalkTrackServices", package: "TalkTrackKit"),
            .product(name: "TalkTrackDomain", package: "TalkTrackKit"),
            "MLXAudioCore",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "Hub", package: "swift-transformers"),
        ]),
        .target(name: "TalkTrackSpeakerMLX", dependencies: [
            .product(name: "TalkTrackDomain", package: "TalkTrackKit"),
            .product(name: "TalkTrackServices", package: "TalkTrackKit"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXNN", package: "mlx-swift"),
        ]),
    ]
)
