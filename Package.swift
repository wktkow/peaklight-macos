// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Peaklight",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Peaklight", targets: ["PeaklightApp"]),
        .executable(name: "PeaklightPolicyTests", targets: ["PeaklightPolicyTests"])
    ],
    targets: [
        .target(
            name: "PeaklightCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("IOKit"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore")
            ]
        ),
        .executableTarget(
            name: "PeaklightApp",
            dependencies: ["PeaklightCore"]
        ),
        .executableTarget(
            name: "PeaklightPolicyTests",
            dependencies: ["PeaklightCore"],
            path: "Tests/PeaklightPolicyTests"
        ),
        .testTarget(
            name: "PeaklightCoreTests",
            dependencies: ["PeaklightCore"]
        )
    ]
)
