// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mac-vnc-server",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "mac-vnc-server-dev",
            targets: ["mac-vnc-server"]
        )
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "mac-vnc-server",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedLibrary("z")
            ]
        ),
        .testTarget(
            name: "mac-vnc-serverTests",
            dependencies: ["mac-vnc-server"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
