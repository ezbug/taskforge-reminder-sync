import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    guard condition() else {
        throw TestFailure(description: message)
    }
}

private func runConflictingModes(
    _ arguments: [String],
    label: String
) throws {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .appendingPathComponent("TaskForgeReminderSync")
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["TASKFORGE_REMINDER_SYNC_TEST_PARSE_ONLY"] = "1"
    process.environment = environment

    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()

    let output = String(
        data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    let error = String(
        data: standardError.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""

    try require(
        process.terminationStatus == 1,
        "\(label): conflicting modes must fail before execution"
    )
    try require(
        error.contains("不能同时指定多个运行模式"),
        "\(label): failure must use the anonymous conflict error"
    )
    for argument in arguments {
        try require(
            !error.contains(argument),
            "\(label): error must not echo a raw argument"
        )
    }
    try require(
        !output.contains("提醒事项权限")
            && !error.contains("提醒事项权限")
            && !output.contains("EventKit")
            && !error.contains("EventKit"),
        "\(label): conflict must fail before EventKit access"
    )
}

private let conflictPairs = [
    ["--prune-dry-run", "--prune-once"],
    ["--restore-last-prune", "--sync"],
    ["--dry-run", "--sync"],
    ["--help", "--prune-once"],
    ["--prune-once", "--prune-once"]
]

do {
    for (index, pair) in conflictPairs.enumerated() {
        try runConflictingModes(pair, label: "pair \(index + 1) forward")
        try runConflictingModes(
            Array(pair.reversed()),
            label: "pair \(index + 1) reverse"
        )
    }
    let testCount = conflictPairs.count * 2
    print("\(testCount)/\(testCount) CLI parser conflict tests passed")
} catch {
    fputs("FAIL  \(error)\n", stderr)
    exit(1)
}
