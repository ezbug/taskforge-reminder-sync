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
        .target(
            name: "TaskForgeReminderEventKit",
            dependencies: ["TaskForgeReminderCore"]
        ),
        .executableTarget(
            name: "TaskForgeReminderSync",
            dependencies: [
                "TaskForgeReminderCore",
                "TaskForgeReminderEventKit"
            ]
        ),
        .executableTarget(
            name: "TaskForgeReminderCoreTests",
            dependencies: [
                "TaskForgeReminderCore",
                "TaskForgeReminderEventKit"
            ],
            path: "Tests/TaskForgeReminderCoreTests"
        ),
        .executableTarget(
            name: "TaskForgeReminderCLITests",
            path: "Tests/TaskForgeReminderCLITests"
        ),
        .executableTarget(
            name: "TaskForgeReminderEventKitTests",
            dependencies: [
                "TaskForgeReminderCore",
                "TaskForgeReminderEventKit"
            ],
            path: "Tests/TaskForgeReminderEventKitTests"
        )
    ]
)
