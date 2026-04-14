// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SafariSidebar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BrowserCore",
            targets: ["BrowserCore"]
        ),
        .executable(
            name: "SigmaBrowserShell",
            targets: ["SigmaBrowserShell"]
        ),
    ],
    targets: [
        .target(
            name: "BrowserCore"
        ),
        .executableTarget(
            name: "SigmaBrowserShell",
            dependencies: ["BrowserCore"]
        ),
        .testTarget(
            name: "BrowserCoreTests",
            dependencies: ["BrowserCore"]
        ),
    ]
)
