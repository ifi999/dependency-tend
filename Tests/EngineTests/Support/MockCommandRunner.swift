import Foundation
@testable import Engine

/// 키 = "실행파일이름 인자들" 공백 join. 스크립트된 응답을 돌려주고 호출(환경 포함)을 기록한다.
final class MockCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let queue = DispatchQueue(label: "dependency-tend.mock-command-runner")
    private var responses: [String: Result<CommandOutput, Error>] = [:]
    private var recordedCalls: [Call] = []

    var calls: [Call] { queue.sync { recordedCalls } }

    func stub(_ key: String, _ output: CommandOutput) {
        queue.sync { responses[key] = .success(output) }
    }

    func stub(_ key: String, error: Error) {
        queue.sync { responses[key] = .failure(error) }
    }

    func run(_ executable: URL, arguments: [String],
             environment: [String: String], timeout: TimeInterval) async throws -> CommandOutput {
        // 전체 경로 키 우선 (같은 이름의 실행 파일이 트리별로 다를 때), 없으면 이름 키
        let pathKey = ([executable.path] + arguments).joined(separator: " ")
        let nameKey = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        let response = queue.sync {
            recordedCalls.append(Call(executablePath: executable.path, arguments: arguments, environment: environment))
            return responses[pathKey] ?? responses[nameKey]
        }
        guard let response else {
            throw CommandError.launchFailed("MockCommandRunner: 스텁 없음 — \(nameKey)")
        }
        return try response.get()
    }
}
