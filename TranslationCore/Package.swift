// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranslationCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TranslationCore", targets: ["TranslationCore"]),
    ],
    targets: [
        .target(name: "TranslationCore"),
        .testTarget(name: "TranslationCoreTests", dependencies: ["TranslationCore"]),
    ]
)
