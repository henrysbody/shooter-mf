// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Kadr",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Kadr", targets: ["Kadr"])],
    targets: [
        .executableTarget(
            name: "Kadr",
            path: "Sources/Kadr",
            resources: [.copy("Fonts")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit")
            ]
        )
    ]
)
