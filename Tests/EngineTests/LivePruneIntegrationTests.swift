import XCTest
@testable import Engine

/// 실기 npm을 상대로 정리(Prune) 전 과정을 검증하는 라이브 테스트.
/// 희생 패키지(left-pad)만 사용하며 사용자 패키지는 건드리지 않는다.
/// 네트워크와 실제 nvm 트리 2개가 필요하므로 TEND_LIVE_PRUNE=1일 때만 실행 (CI/평소엔 skip).
final class LivePruneIntegrationTests: XCTestCase {
    func testRealNpmPruneAndRestoreRoundTrip() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TEND_LIVE_PRUNE"] == "1",
                          "실기 npm 라이브 테스트 — TEND_LIVE_PRUNE=1로만 실행")
        let tools = ToolLocator().npmInstallations().filter { $0.source == "nvm" }
        try XCTSkipUnless(tools.count >= 2, "nvm 트리 2개 필요")
        let treeKeep = tools[0]   // 낮은 버전 정렬 첫 트리 — 최신 버전을 설치해 keep으로
        let treeStale = tools[1]  // 잔재 역할 — 낮은 버전 설치
        let runner = ProcessCommandRunner()
        let sacrifice = "left-pad"

        @Sendable func npm(_ tool: ToolLocator.NpmTool, _ args: [String]) async throws -> CommandOutput {
            try await runner.run(tool.npm, arguments: args,
                                 environment: ["PATH": "\(tool.binDir.path):/usr/bin:/bin"],
                                 timeout: 180)
        }

        // 셋업: 두 트리에 서로 다른 버전 설치 (트리 간 중복 잔재 상황 재현)
        let setupKeep = try await npm(treeKeep, ["install", "-g", "\(sacrifice)@1.3.0"])
        XCTAssertEqual(setupKeep.exitCode, 0, "셋업 실패: \(setupKeep.stderr)")
        let setupStale = try await npm(treeStale, ["install", "-g", "\(sacrifice)@1.2.0"])
        XCTAssertEqual(setupStale.exitCode, 0, "셋업 실패: \(setupStale.stderr)")

        // 어떤 경로로 빠져도 희생 패키지는 정리한다
        addTeardownBlock {
            _ = try? await npm(treeKeep, ["uninstall", "-g", sacrifice])
            _ = try? await npm(treeStale, ["uninstall", "-g", sacrifice])
        }

        // 1) 실제 어댑터 스캔 → 중복이 두 트리에 잡히나
        let adapter = NpmGlobalAdapter(tools: [treeKeep, treeStale], runner: runner)
        let scan = try await adapter.scan(now: Date())
        XCTAssertEqual(scan.packages.filter { $0.name == sacrifice }.count, 2)

        // 2) 실제 advisor → 낮은 버전(treeStale)이 잔재로, 차단 없이 제안되나
        let suggestions = PruneAdvisor.suggestions(packages: scan.packages,
                                                   defaultNpmTreeLabel: treeKeep.label)
        let suggestion = try XCTUnwrap(suggestions.first { $0.target.name == sacrifice })
        XCTAssertEqual(suggestion.target.current, "1.2.0")
        XCTAssertEqual(suggestion.target.metadata["tree"], treeStale.label)
        XCTAssertNil(suggestion.blockReason)

        // 3) 실제 executor로 삭제 → 해당 트리에서만 사라지나
        let executor = UpdateExecutor(runner: runner)
        let removeResult = await executor.run(suggestion.removeCommand, packageID: suggestion.target.id)
        XCTAssertTrue(removeResult.succeeded, "삭제 실패: \(removeResult.stderr)")

        let afterRemove = try await adapter.scan(now: Date())
        let remaining = afterRemove.packages.filter { $0.name == sacrifice }
        XCTAssertEqual(remaining.count, 1, "keep 트리 것만 남아야 함")
        XCTAssertEqual(remaining.first?.metadata["tree"], treeKeep.label)
        XCTAssertEqual(remaining.first?.current, "1.3.0")

        // 4) 복원 명령(버전 박제) → 삭제 당시 버전 그대로 돌아오나
        let restoreResult = await executor.run(suggestion.restoreCommand, packageID: suggestion.target.id)
        XCTAssertTrue(restoreResult.succeeded, "복구 실패: \(restoreResult.stderr)")

        let afterRestore = try await adapter.scan(now: Date())
        let restored = afterRestore.packages.first {
            $0.name == sacrifice && $0.metadata["tree"] == treeStale.label
        }
        XCTAssertEqual(restored?.current, "1.2.0", "삭제 당시 버전으로 복원되어야 함")
    }
}
