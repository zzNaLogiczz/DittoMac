// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DittoMac",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "DittoMacKit",
            path: "Sources/DittoMacKit",
            resources: [
                // 内置主题(上游 Debug/Themes 的 12 个 XML;ThemeRegistry 经
                // Bundle.module 读取,直连源码编译时回退 #filePath —— 见 DittoThemeFile.swift)
                .copy("Resources/Themes"),
            ]
        ),
        .executableTarget(
            name: "DittoMac",
            dependencies: ["DittoMacKit"],
            path: "Sources/DittoMac"
        ),
    ]
)
