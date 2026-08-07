// swift-tools-version: 6.3
import PackageDescription

let lifetimeSettings: [SwiftSetting] = [
    .enableExperimentalFeature("Lifetimes"),
]

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
        .target(name: "ProtoCacheCore", swiftSettings: lifetimeSettings),
        .target(
            name: "ProtoCache",
            dependencies: [
                "ProtoCacheCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: lifetimeSettings
        ),
        .executableTarget(
            name: "ProtoCacheGenerator",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
            ],
            swiftSettings: lifetimeSettings
        ),
        .testTarget(
            name: "ProtoCacheCoreTests",
            dependencies: ["ProtoCacheCore"],
            swiftSettings: lifetimeSettings
        ),
        .testTarget(
            name: "ProtoCacheTests",
            dependencies: [
                "ProtoCache",
                "ProtoCacheCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: lifetimeSettings
        ),
        .testTarget(
            name: "ProtoCacheGeneratorTests",
            dependencies: [
                "ProtoCacheGenerator",
                "ProtoCacheCore",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "SwiftProtobufPluginLibrary", package: "swift-protobuf"),
            ],
            swiftSettings: lifetimeSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
