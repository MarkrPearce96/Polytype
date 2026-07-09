// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypeTranslatorApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../TranslationCore"),
    ],
    targets: [
        .executableTarget(
            name: "TypeTranslator",
            dependencies: [
                .product(name: "TranslationCore", package: "TranslationCore"),
            ]
        ),
    ]
)
