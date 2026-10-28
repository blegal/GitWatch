// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitWatch",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "GitWatch", targets: ["GitWatch"]),
    ],
    targets: [
        .executableTarget(
            name: "GitWatch",
            path: "Sources/GitWatch",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
