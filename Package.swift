// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "tokencat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "tokencat",
            path: "Sources/tokencat"
        )
    ],
    swiftLanguageVersions: [.v5]
)
