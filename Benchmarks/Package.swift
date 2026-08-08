// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "protocache-benchmarks",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(name: "protocache-swift", path: ".."),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        .package(url: "https://github.com/google/flatbuffers.git", exact: "25.12.19"),
    ],
    targets: [
        .executableTarget(
            name: "Benchmark",
            dependencies: [
                .product(name: "protocache-core", package: "protocache-swift"),
                .product(name: "protocache", package: "protocache-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "FlatBuffers", package: "flatbuffers"),
            ],
            path: "Sources/Benchmark",
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableExperimentalFeature("Lifetimes")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
