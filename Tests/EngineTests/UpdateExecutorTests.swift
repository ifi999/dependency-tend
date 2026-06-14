import XCTest
@testable import Engine

private struct FixedCommandAdapter: PackageManagerAdapter {
    let id = ManagerID.homebrew
    let command: UpdateCommand?
    func isAvailable() -> Bool { true }
    func scan(now: Date) async throws -> AdapterScan { AdapterScan(packages: []) }
    func updateCommand(for pkg: PackageInfo) -> UpdateCommand? { command }
}

final class UpdateExecutorTests: XCTestCase {
    let pkg = PackageInfo(name: "aom", manager: .homebrew, status: .outdated)

    func testSuccess() async {
        let runner = MockCommandRunner()
        runner.stub("brew upgrade aom",
                    CommandOutput(stdout: "Upgrading aom\n", stderr: "", exitCode: 0))
        let adapter = FixedCommandAdapter(command: UpdateCommand(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["upgrade", "aom"]))
        let result = await UpdateExecutor(runner: runner).update(pkg, using: adapter)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.command, "/opt/homebrew/bin/brew upgrade aom")
        XCTAssertEqual(result.stdout, "Upgrading aom\n")
    }

    func testFailureIsReportedFaithfully() async {
        let runner = MockCommandRunner()
        runner.stub("brew upgrade aom",
                    CommandOutput(stdout: "", stderr: "Error: aom not installed", exitCode: 1))
        let adapter = FixedCommandAdapter(command: UpdateCommand(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["upgrade", "aom"]))
        let result = await UpdateExecutor(runner: runner).update(pkg, using: adapter)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.stderr.contains("not installed")) // stderr 원문 보존
    }

    func testRunnerErrorBecomesFailedResult() async {
        let runner = MockCommandRunner()
        runner.stub("brew upgrade aom", error: CommandError.timeout("brew"))
        let adapter = FixedCommandAdapter(command: UpdateCommand(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            arguments: ["upgrade", "aom"]))
        let result = await UpdateExecutor(runner: runner).update(pkg, using: adapter)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertTrue(result.stderr.contains("timeout"))
    }

    func testUnsupportedPackage() async {
        let adapter = FixedCommandAdapter(command: nil)
        let result = await UpdateExecutor(runner: MockCommandRunner()).update(pkg, using: adapter)
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.exitCode, -1)
    }

    func testConcurrentUpdatesDoNotOverlap() async {
        // actor는 await 지점에서 재진입한다 — task-chaining이 실제로 순차를 보장하는지 검증
        final class SlowRecordingRunner: CommandRunning, @unchecked Sendable {
            private let queue = DispatchQueue(label: "dependency-tend.slow-recording-runner")
            private var recordedIntervals: [(start: Date, end: Date)] = []
            var intervals: [(start: Date, end: Date)] { queue.sync { recordedIntervals } }
            func run(_ executable: URL, arguments: [String],
                     environment: [String: String], timeout: TimeInterval) async throws -> CommandOutput {
                let start = Date()
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                let end = Date()
                queue.sync { recordedIntervals.append((start, end)) }
                return CommandOutput(stdout: "", stderr: "", exitCode: 0)
            }
        }
        let runner = SlowRecordingRunner()
        let executor = UpdateExecutor(runner: runner)
        let pkg = PackageInfo(name: "aom", manager: .homebrew, status: .outdated)
        let adapter = FixedCommandAdapter(command: UpdateCommand(
            executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"]))
        async let first = executor.update(pkg, using: adapter)
        async let second = executor.update(pkg, using: adapter)
        _ = await (first, second)
        let sorted = runner.intervals.sorted { $0.start < $1.start }
        XCTAssertEqual(sorted.count, 2)
        XCTAssertLessThanOrEqual(sorted[0].end, sorted[1].start, "두 업데이트가 시간상 겹치면 안 된다")
    }
}
