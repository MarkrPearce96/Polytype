// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypeTranslatorApp",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../TranslationCore"),
    ],
    targets: [
        // Menu-bar + global-hotkey app: type in any app, press the hotkey, and
        // the text is translated in place. Uses TranslationCore for the engines.
        .executableTarget(
            name: "TypeTranslatorBar",
            dependencies: [
                .product(name: "TranslationCore", package: "TranslationCore"),
            ]
        ),
    ]
)
