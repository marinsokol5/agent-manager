// swift-tools-version: 6.0
import PackageDescription

// Agent Manager — one Swift package.
//
// `AgentManagerCore` is the shared library (account model, managed homes,
// symlink farm, guided login, identity verification, audit log). `am` is the
// CLI that drives Core end-to-end, and a SwiftUI menu-bar `App` target — all
// three surfaces over the same Core.
//
// `am-wake-helper` is deliberately *not* one of those surfaces: it is the tiny
// root daemon that arms RTC wakes for scheduled pings, and it links only
// `WakeHelperCore` (Foundation-only planning/parsing) — never
// `AgentManagerCore` — so the binary that runs as root contains no account,
// keychain, network, or process-spawning code and stays independently
// auditable.
let package = Package(
    name: "AgentManager",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentManagerCore", targets: ["AgentManagerCore"]),
        .executable(name: "am", targets: ["am"]),
        .executable(name: "AgentManager", targets: ["AgentManager"]),
        .executable(name: "am-wake-helper", targets: ["am-wake-helper"]),
    ],
    targets: [
        .target(
            name: "AgentManagerCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .target(
            name: "WakeHelperCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "am-wake-helper",
            dependencies: ["WakeHelperCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "AgentManager",
            dependencies: ["AgentManagerCore"],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .executableTarget(
            name: "am",
            dependencies: ["AgentManagerCore"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]),
        .testTarget(
            name: "AgentManagerCoreTests",
            // Links the app executable too (SwiftPM 5.5+) so the theme-contrast
            // audit can read the real design tokens in `Theme` instead of copies.
            dependencies: ["AgentManagerCore", "WakeHelperCore", "AgentManager"]),
    ])
