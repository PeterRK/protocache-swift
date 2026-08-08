// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ProtoCachePackageConsumer",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    dependencies: [
        .package(name: "protocache-swift", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [
                .product(name: "protocache-core", package: "protocache-swift"),
                .product(name: "protocache", package: "protocache-swift"),
            ],
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
