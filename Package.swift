// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "protocache-swift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "protocache-core", targets: ["ProtoCacheCore"]),
        .library(name: "protocache", targets: ["ProtoCache"]),
        .executable(name: "protoc-gen-pcsw", targets: ["ProtoCacheGenerator"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    ],
    targets: [
        .target(name: "ProtoCacheCore"),
        .target(
            name: "ProtoCache",
            dependencies: [
                "ProtoCacheCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "ProtoCacheGenerator",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
            ]
        ),
        .testTarget(name: "ProtoCacheCoreTests", dependencies: ["ProtoCacheCore"]),
        .testTarget(
            name: "ProtoCacheTests",
            dependencies: [
                "ProtoCache",
                "ProtoCacheCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .testTarget(
            name: "ProtoCacheGeneratorTests",
            dependencies: [
                "ProtoCacheGenerator",
                "ProtoCacheCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "ProtoCacheBenchmarks",
            dependencies: [
                "ProtoCacheCore",
                "ProtoCache",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Benchmarks/ProtoCacheBenchmarks",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
