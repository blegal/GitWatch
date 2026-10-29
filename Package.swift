// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitWatch",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "GitWatch", targets: ["GitWatch"]),
    ],
    dependencies: [
        // Mise à jour automatique (bibliothèque partagée avec iExplorer et iBaobab).
        .package(url: "https://github.com/blegal/iBaobab", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "GitWatch",
            dependencies: [.product(name: "UpdateKit", package: "iBaobab")],
            path: "Sources/GitWatch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
