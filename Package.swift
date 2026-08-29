// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "Peaklight",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Peaklight", targets: ["PeaklightApp"]),
    .executable(
      name: "PeaklightInstallHelper",
      targets: ["PeaklightInstallHelper"]
    ),
    .executable(name: "PeaklightPolicyTests", targets: ["PeaklightPolicyTests"]),
  ],
  targets: [
    .target(
      name: "PeaklightObjCShim",
      path: "Sources/PeaklightObjCShim",
      publicHeadersPath: "include"
    ),
    .target(
      name: "PeaklightCore",
      dependencies: ["PeaklightObjCShim"],
      linkerSettings: [
        .linkedFramework("AppKit"),
        .linkedFramework("ApplicationServices"),
        .linkedFramework("IOKit"),
        .linkedFramework("MetalKit"),
        .linkedFramework("QuartzCore"),
      ]
    ),
    .executableTarget(
      name: "PeaklightApp",
      dependencies: ["PeaklightCore"]
    ),
    .target(name: "PeaklightInstallSupport"),
    .executableTarget(
      name: "PeaklightInstallHelper",
      dependencies: ["PeaklightCore", "PeaklightInstallSupport"],
      linkerSettings: [.linkedFramework("Security")]
    ),
    .executableTarget(
      name: "PeaklightPolicyTests",
      dependencies: ["PeaklightCore"],
      path: "Tests/PeaklightPolicyTests"
    ),
    .testTarget(
      name: "PeaklightCoreTests",
      dependencies: ["PeaklightCore", "PeaklightObjCShim"]
    ),
    .testTarget(
      name: "PeaklightInstallSupportTests",
      dependencies: ["PeaklightInstallSupport"]
    ),
  ]
)
