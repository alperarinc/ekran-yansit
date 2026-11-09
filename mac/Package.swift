// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EkranYansit",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "VirtualDisplayShim", linkerSettings: [.linkedFramework("CoreGraphics")]),
        .executableTarget(name: "EkranYansit", dependencies: ["VirtualDisplayShim"]),
    ]
)
