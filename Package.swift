// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Xotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Xotch",
            path: "Sources/Xotch"
        )
    ]
)
