import Foundation

/// 모든 업데이트를 전역 순차 실행한다 (brew lock 경합 원천 차단).
/// 주의: actor는 await 지점에서 재진입하므로, 명시적 task-chaining으로 순차를 보장한다.
/// 실패를 성공으로 보고하지 않는다: exit code와 stderr를 원문 그대로 UpdateResult에 담는다.
public actor UpdateExecutor {
    private let runner: any CommandRunning
    private let timeout: TimeInterval
    private var tail: Task<Void, Never>?

    /// 대형 cask(수 GB 다운로드)를 고려해 기본 30분
    public init(runner: any CommandRunning, timeout: TimeInterval = 1800) {
        self.runner = runner
        self.timeout = timeout
    }

    public func update(_ pkg: PackageInfo, using adapter: any PackageManagerAdapter) async -> UpdateResult {
        guard let cmd = adapter.updateCommand(for: pkg) else {
            return UpdateResult(packageID: pkg.id, command: "(미지원)", stdout: "",
                                stderr: "이 패키지는 자동 업데이트를 지원하지 않습니다", exitCode: -1)
        }
        return await run(cmd, packageID: pkg.id)
    }

    /// 임의 명령(삭제/복구/autoremove 등)도 같은 직렬 큐로 실행 — 정리 기능이 재사용 (정리 스펙 §4)
    public func run(_ command: UpdateCommand, packageID: String) async -> UpdateResult {
        let previous = tail
        let work = Task { [runner, timeout] () -> UpdateResult in
            await previous?.value // 직전 작업 완료를 기다린다 (체이닝)
            do {
                let output = try await runner.run(command.executable, arguments: command.arguments,
                                                  environment: command.environment, timeout: timeout)
                return UpdateResult(packageID: packageID, command: command.displayString,
                                    stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode)
            } catch {
                return UpdateResult(packageID: packageID, command: command.displayString,
                                    stdout: "", stderr: String(describing: error), exitCode: -1)
            }
        }
        tail = Task { _ = await work.value }
        return await work.value
    }
}
