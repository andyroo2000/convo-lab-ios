// swift-tools-version: 6.1
import PackageDescription
let flags: [SwiftSetting] = [.define("Zenzai"), .enableUpcomingFeature("InternalImportsByDefault"), .interoperabilityMode(.Cxx)]
let package = Package(
    name: "JournalTypingEngine", platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "PlaygroundEngine", targets: ["PlaygroundEngine"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-algorithms", exact: "1.2.1"),
        .package(url: "https://github.com/apple/swift-collections", exact: "1.7.6")
    ],
    targets: [
        .binaryTarget(name: "llama.cpp", url: "https://github.com/azooKey/llama.cpp/releases/download/b4846/signed-llama.xcframework.zip", checksum: "db3b13169df8870375f212e6ac21194225f1c85f7911d595ab64c8c790068e0a"),
        .target(name: "SwiftUtils", dependencies: [.product(name: "Algorithms", package: "swift-algorithms")], path: "Vendor/AzooKey/Sources/SwiftUtils", swiftSettings: flags),
        .target(name: "EfficientNGram", path: "Vendor/Personalization", swiftSettings: flags),
        .target(name: "KanaKanjiConverterModule", dependencies: ["SwiftUtils", "EfficientNGram", "llama.cpp", .product(name: "Collections", package: "swift-collections")], path: "Vendor/AzooKey/Sources/KanaKanjiConverterModule", swiftSettings: flags),
        .target(name: "KanaKanjiConverterModuleWithDefaultDictionary", dependencies: ["KanaKanjiConverterModule"], path: "Vendor/AzooKey/Sources/KanaKanjiConverterModuleWithDefaultDictionary", exclude: ["azooKey_dictionary_storage/README.md", "azooKey_dictionary_storage/LICENSE", "azooKey_emoji_dictionary_storage/data", "azooKey_emoji_dictionary_storage/scripts", "azooKey_emoji_dictionary_storage/requirements.txt", "azooKey_emoji_dictionary_storage/README.md"], resources: [.copy("azooKey_dictionary_storage/Dictionary"), .copy("azooKey_emoji_dictionary_storage/EmojiDictionary")], swiftSettings: flags),
        .target(name: "PlaygroundEngine", dependencies: ["KanaKanjiConverterModuleWithDefaultDictionary"], resources: [.copy("Resources")], swiftSettings: flags),
        .testTarget(name: "PlaygroundEngineTests", dependencies: ["PlaygroundEngine"], swiftSettings: flags)
    ]
)
