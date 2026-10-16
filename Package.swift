// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "pagecap",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PageCapCore", path: "Sources/PageCapCore"),
        .executableTarget(name: "pagecap", dependencies: ["PageCapCore"], path: "Sources/pagecap"),
        .executableTarget(name: "PageCapApp", dependencies: ["PageCapCore"], path: "Sources/PageCapApp"),
    ]
)
