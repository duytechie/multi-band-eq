// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MultiBandEQ",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "MultiBandEQ", targets: ["MultiBandEQ"])],
    targets: [
        .target(name: "EQDSP", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreAudio")]),
        .target(name: "EQKit", dependencies: ["EQDSP"]),
        .executableTarget(name: "MultiBandEQ", dependencies: ["EQKit", "EQDSP"], linkerSettings: [
            .linkedFramework("CoreAudio"), .linkedFramework("AppKit"), .linkedFramework("SwiftUI")
        ]),
        .testTarget(name: "EQKitTests", dependencies: ["EQKit", "EQDSP"])
    ]
)
