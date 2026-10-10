// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "EyesDriven2me",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "EyesDriven2me", targets: ["EyesDrivenApp"]),
        .library(name: "EyesDrivenCore", targets: ["EyesDrivenCore"]),
    ],
    targets: [
        .target(
            name: "EyesDrivenCore",
            path: "Sources/EyesDrivenCore"
        ),
        .executableTarget(
            name: "EyesDrivenApp",
            dependencies: ["EyesDrivenCore"],
            path: "Sources/EyesDrivenApp",
            linkerSettings: [
                // Embed Info.plist so the bare binary (swift run) can ask for camera access.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ]),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "EyesDrivenCoreTests",
            dependencies: ["EyesDrivenCore"],
            path: "Tests/EyesDrivenCoreTests"
        ),
    ]
)
