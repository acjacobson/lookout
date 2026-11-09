// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lookout",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Lookout", path: "Sources/Lookout")
    ]
)
