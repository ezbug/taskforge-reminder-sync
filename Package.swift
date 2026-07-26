// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TaskForgeReminderSync",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TaskForgeReminderCore",
            targets: ["TaskForgeReminderCore"]
        ),
        .executable(
            name: "TaskForgeReminderSync",
            targets: ["TaskForgeReminderSync"]
        )
    ],
    targets: [
        .target(
            name: "TaskForgeReminderCore"
        ),
        .executableTarget(
            name: "TaskForgeReminderSync",
            dependencies: ["TaskForgeReminderCore"]
        ),
        .executableTarget(
            name: "TaskForgeReminderCoreTests",
            dependencies: ["TaskForgeReminderCore"],
            path: "Tests/TaskForgeReminderCoreTests"
        )
    ]
)
