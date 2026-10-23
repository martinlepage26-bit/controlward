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
            // ControlWardLogo loads controlward-mark.png. The SVG is source art and is not bundled.
            exclude: ["Resources/controlward-mark.svg"],
            // Resources/config holds icp.json and icp.confirmed.json for the lead pipeline (Slice 3).
            resources: [.process("Resources/controlward-mark.png"), .copy("Resources/ProjectControl"), .copy("Resources/config")]
        ),
    ]
)
