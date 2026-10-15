// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DittoMac",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DittoMacKit",
            path: "Sources/DittoMacKit"
        ),
        .executableTarget(
            name: "DittoMac",
            dependencies: ["DittoMacKit"],
            path: "Sources/DittoMac"
        ),
    ]
)
