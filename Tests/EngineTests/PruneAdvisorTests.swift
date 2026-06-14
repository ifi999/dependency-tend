import XCTest
@testable import Engine

final class PruneAdvisorTests: XCTestCase {
    private func npmPkg(_ name: String, version: String, tree: String,
                        npmPath: String = "/fake/bin/npm",
                        flags: Set<PackageFlag> = []) -> PackageInfo {
        PackageInfo(name: name, manager: .npmGlobal, current: version,
                    status: .upToDate, flags: flags,
                    metadata: ["tree": tree, "npmPath": npmPath, "node": "18.19.1"])
    }

    private func mcp(_ name: String, detail: String) -> PackageInfo {
        PackageInfo(name: "mcp:\(name)", manager: .claudePlugin, status: .unknown,
                    metadata: ["kind": "mcp", "mcpKind": "local", "mcpDetail": detail])
    }

    func testSuggestsLowerVersionDuplicate() {
        let packages = [
            npmPkg("@openai/codex", version: "0.139.0", tree: "v18.19.1 (nvm)", npmPath: "/nvm18/bin/npm"),
            npmPkg("@openai/codex", version: "0.101.0", tree: "v22.21.1 (nvm)", npmPath: "/nvm22/bin/npm"),
        ]
        let suggestions = PruneAdvisor.suggestions(packages: packages)
        XCTAssertEqual(suggestions.count, 1)
        let s = suggestions[0]
        XCTAssertEqual(s.target.metadata["tree"], "v22.21.1 (nvm)") // 낮은 버전이 잔재
        XCTAssertNil(s.blockReason)
        // 증거: keep 쪽 정보가 들어가야 한다
        XCTAssertTrue(s.evidence.contains("0.139.0"))
        XCTAssertTrue(s.evidence.contains("v18.19.1 (nvm)"))
        // 삭제는 해당 트리의 npm으로, 복원은 버전 박제
        XCTAssertEqual(s.removeCommand.executable.path, "/nvm22/bin/npm")
        XCTAssertEqual(s.removeCommand.arguments, ["uninstall", "-g", "@openai/codex"])
        XCTAssertEqual(s.restoreCommand.arguments, ["install", "-g", "@openai/codex@0.101.0"])
    }

    func testTieKeepsDefaultTree() {
        let packages = [
            npmPkg("openai-oauth", version: "1.0.2", tree: "v18.19.1 (nvm)", npmPath: "/nvm18/bin/npm"),
            npmPkg("openai-oauth", version: "1.0.2", tree: "v22.21.1 (nvm)", npmPath: "/nvm22/bin/npm"),
        ]
        let suggestions = PruneAdvisor.suggestions(packages: packages,
                                                   defaultNpmTreeLabel: "v18.19.1 (nvm)")
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions[0].target.metadata["tree"], "v22.21.1 (nvm)") // default가 아닌 쪽이 잔재
    }

    func testMCPReferencedPackageIsBlocked() {
        // mcpDetail "codegraph serve --mcp"는 스코프 패키지명의 마지막 컴포넌트와 일치 → 차단
        let packages = [
            npmPkg("@colbymchenry/codegraph", version: "1.0.0", tree: "v18.19.1 (nvm)"),
            npmPkg("@colbymchenry/codegraph", version: "0.9.0", tree: "v22.21.1 (nvm)"),
            mcp("codegraph", detail: "codegraph serve --mcp"),
        ]
        let suggestions = PruneAdvisor.suggestions(packages: packages)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertNotNil(suggestions[0].blockReason)
        XCTAssertTrue(suggestions[0].blockReason?.contains("MCP") == true)
    }

    func testUnparseableVersionGroupIsSkipped() {
        // 재검증 B1: 한쪽이라도 버전을 못 읽으면 keep을 확신할 수 없다 — 제안 자체를 포기 (보수)
        let packages = [
            npmPkg("tool", version: "1.0.0", tree: "v18.19.1 (nvm)"),
            npmPkg("tool", version: "next", tree: "v22.21.1 (nvm)"), // dist-tag — 파싱 불가
        ]
        XCTAssertTrue(PruneAdvisor.suggestions(packages: packages).isEmpty)
    }

    func testTieWithoutDefaultTreeIsSkipped() {
        // 재검증 B2: 동률인데 어느 트리가 실사용(PATH 우선)인지 모르면 판정하지 않는다
        let packages = [
            npmPkg("tool", version: "1.0.0", tree: "v18.19.1 (nvm)"),
            npmPkg("tool", version: "1.0.0", tree: "v22.21.1 (nvm)"),
        ]
        XCTAssertTrue(PruneAdvisor.suggestions(packages: packages).isEmpty) // default 미지정
        XCTAssertTrue(PruneAdvisor.suggestions(packages: packages,
                                               defaultNpmTreeLabel: "없는 라벨").isEmpty) // 불일치
    }

    func testBinNameMatchBlocksMCPReference() {
        // 재검증 B3: bin 이름 ≠ 패키지명인 경우 — 어댑터가 수집한 bins로 매칭
        var lower = npmPkg("@modelcontextprotocol/server-fs", version: "0.9.0", tree: "v22.21.1 (nvm)")
        lower.metadata["bins"] = "mcp-server-fs"
        let packages = [
            npmPkg("@modelcontextprotocol/server-fs", version: "1.0.0", tree: "v18.19.1 (nvm)"),
            lower,
            mcp("fs", detail: "mcp-server-fs --root /"), // 패키지명은 안 나오고 bin만 등장
        ]
        let suggestions = PruneAdvisor.suggestions(packages: packages)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertNotNil(suggestions[0].blockReason)
    }

    func testUnknowableMCPBlocksAllSuggestions() {
        // 해석 불가한 로컬 MCP가 있으면 참조를 판정할 수 없다 — 전부 차단 (보수)
        let unknowableMCP = PackageInfo(name: "mcp:mystery", manager: .claudePlugin,
                                        status: .unknown, metadata: ["kind": "mcp"]) // detail 없음
        let packages = [
            npmPkg("tool", version: "2.0.0", tree: "v18.19.1 (nvm)"),
            npmPkg("tool", version: "1.0.0", tree: "v22.21.1 (nvm)"),
            unknowableMCP,
        ]
        let suggestions = PruneAdvisor.suggestions(packages: packages)
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertTrue(suggestions[0].blockReason?.contains("판정") == true)
    }

    func testSingleInstanceAndBundledAreIgnored() {
        let packages = [
            npmPkg("ccusage", version: "17.1.6", tree: "v18.19.1 (nvm)"),       // 단일 → 제안 없음
            npmPkg("npm", version: "10.2.4", tree: "v18.19.1 (nvm)", flags: [.dependency]), // 번들 → 무시
            npmPkg("npm", version: "10.9.0", tree: "v22.21.1 (nvm)", flags: [.dependency]),
        ]
        XCTAssertTrue(PruneAdvisor.suggestions(packages: packages).isEmpty)
    }
}
