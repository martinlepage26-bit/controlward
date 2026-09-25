// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "FollowUpOSNative",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FollowUpOSNative", targets: ["FollowUpOSNative"]),
    ],
    targets: [
        .executableTarget(
            name: "FollowUpOSNative",
            path: "Sources/FollowUpOSNative",
            resources: [.process("Resources")]
        ),
    ]
)
