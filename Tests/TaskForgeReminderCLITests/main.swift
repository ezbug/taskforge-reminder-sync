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

private struct ParserResult {
    let status: Int32
    let output: String
    let error: String
}

private func runParser(_ arguments: [String]) throws -> ParserResult {
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

    return ParserResult(
        status: process.terminationStatus,
        output: output,
        error: error
    )
}

private func runConflictingModes(
    _ arguments: [String],
    label: String
) throws {
    let result = try runParser(arguments)
    try require(
        result.status == 1,
        "\(label): conflicting modes must fail before execution"
    )
    try require(
        result.error.contains("不能同时指定多个运行模式"),
        "\(label): failure must use the anonymous conflict error"
    )
    for argument in arguments {
        try require(
            !result.error.contains(argument),
            "\(label): error must not echo a raw argument"
        )
    }
    try require(
        !result.output.contains("提醒事项权限")
            && !result.error.contains("提醒事项权限")
            && !result.output.contains("EventKit")
            && !result.error.contains("EventKit"),
        "\(label): conflict must fail before EventKit access"
    )
}

private func requireMode(
    _ arguments: [String],
    expected: String,
    label: String
) throws {
    let result = try runParser(arguments)
    try require(
        result.status == 0,
        "\(label): one mode should parse successfully"
    )
    try require(
        result.output == "parse-mode=\(expected)\n",
        "\(label): unexpected anonymous mode label \(result.output)"
    )
    try require(
        result.error.isEmpty,
        "\(label): parse-only mode wrote stderr"
    )
    try require(
        !result.output.contains("提醒事项权限")
            && !result.output.contains("EventKit"),
        "\(label): parse-only mode reached EventKit"
    )
}

private let conflictPairs = [
    ["--prune-dry-run", "--prune-once"],
    ["--restore-last-prune", "--sync"],
    ["--dry-run", "--sync"],
    ["--help", "--prune-once"],
    ["--prune-once", "--prune-once"]
]

private let singleModes: [([String], String)] = [
    ([], "dry-run"),
    (["--check-config"], "check-config"),
    (["--dry-run"], "dry-run"),
    (["--audit"], "audit"),
    (["--deduplicate-dry-run"], "deduplicate-dry-run"),
    (["--deduplicate"], "deduplicate"),
    (["--sync"], "sync"),
    (["--reverse-dry-run"], "reverse-dry-run"),
    (["--reverse-once"], "reverse-once"),
    (["--prune-dry-run"], "prune-dry-run"),
    (["--prune-once"], "prune-once"),
    (["--restore-last-prune"], "restore-last-prune"),
    (["--watch"], "watch"),
    (["--help"], "help"),
    (["--source", "custom-list"], "dry-run"),
    (["--source", "scheduled-day", "--date", "2026-08-04"], "dry-run")
]

private func requireSourceCompatibilityRules() throws {
    let result = try runParser([
        "--source", "custom-list", "--date", "2026-08-04"
    ])
    try require(
        result.status == 1
            && result.error.contains("scheduled-day"),
        "custom-list must reject legacy date selection"
    )
    try require(
        !result.error.contains("2026-08-04"),
        "parser error must not echo a date value"
    )
    let unknown = try runParser(["--source", "not-a-source"])
    try require(
        unknown.status == 1
            && unknown.error.contains("custom-list")
            && unknown.error.contains("scheduled-day"),
        "unknown source must fail closed"
    )
}

do {
    for (index, pair) in conflictPairs.enumerated() {
        try runConflictingModes(pair, label: "pair \(index + 1) forward")
        try runConflictingModes(
            Array(pair.reversed()),
            label: "pair \(index + 1) reverse"
        )
    }
    for (arguments, expected) in singleModes {
        try requireMode(
            arguments,
            expected: expected,
            label: arguments.first ?? "no mode"
        )
    }
    try requireSourceCompatibilityRules()
    let testCount = conflictPairs.count * 2 + singleModes.count
    print("\(testCount)/\(testCount) CLI parser tests passed")
} catch {
    fputs("FAIL  \(error)\n", stderr)
    exit(1)
}
