import Foundation

/// 정리(가지치기) 제안 — 결론이 아니라 증거를 함께 낸다 (정리 스펙 §2-②).
public struct PruneSuggestion: Identifiable, Equatable, Sendable {
    public let target: PackageInfo
    /// 왜 잔재로 판단했는지 — UI에 그대로 노출
    public let evidence: String
    /// nil이면 삭제 가능. 값이 있으면 차단 사유 (예: MCP가 사용 중) — 버튼 대신 사유 표시
    public let blockReason: String?
    /// 삭제 실행 명령 (해당 트리의 npm으로 라우팅)
    public let removeCommand: UpdateCommand
    /// 복구 장부에 박제할 복원 명령 — 버전 고정
    public let restoreCommand: UpdateCommand
    public var id: String { target.id }
}

/// 잔재 감지 — 순수 함수 (정리 스펙 §3).
/// 핵심 원칙(재검증 반영): **판단할 수 없으면 제안하지 않는다.**
/// 버전 파싱 실패·동률에 default 트리 부재 등 keep을 확신할 수 없는 그룹은 통째로 건너뛴다 —
/// 사전순 폴백 같은 임의 판정이 "최신/사용 중인 본 삭제"로 이어지는 경로를 차단.
public enum PruneAdvisor {
    public static func suggestions(packages: [PackageInfo],
                                   defaultNpmTreeLabel: String? = nil) -> [PruneSuggestion] {
        // npm/corepack 같은 번들(dependency 플래그)은 트리와 함께 사라지므로 제외
        let npmDirect = packages.filter {
            $0.manager == .npmGlobal && !$0.flags.contains(.dependency)
        }
        let mcp = mcpReferenceInfo(packages: packages)

        var result: [PruneSuggestion] = []
        let groups = Dictionary(grouping: npmDirect, by: \.name)
        for (name, instances) in groups.sorted(by: { $0.key < $1.key }) where instances.count > 1 {
            guard let keep = keepInstance(of: instances, defaultTree: defaultNpmTreeLabel) else {
                continue // keep을 확신할 수 없는 그룹 — 제안 포기 (보수)
            }
            for instance in instances where instance.id != keep.id {
                guard let suggestion = makeSuggestion(for: instance, keep: keep,
                                                      name: name, mcp: mcp) else { continue }
                result.append(suggestion)
            }
        }
        return result
    }

    /// keep 규칙 (재검증 반영): ① 전 인스턴스 버전이 파싱돼야 비교 자격 ② 최고 버전
    /// ③ 최고 버전 동률이면 default 트리가 그중에 있을 때만 그것을 keep — 아니면 판정 불가(nil)
    static func keepInstance(of instances: [PackageInfo],
                             defaultTree: String?) -> PackageInfo? {
        let parsed = instances.compactMap { pkg in
            pkg.current.flatMap(SemVer.parse).map { (pkg: pkg, version: $0) }
        }
        guard parsed.count == instances.count else { return nil } // 파싱 실패 포함 → 판정 불가
        guard let top = parsed.map(\.version).max() else { return nil }
        let tied = parsed.filter { $0.version == top }.map(\.pkg)
        if tied.count == 1 { return tied[0] }
        // 동률: 어느 트리가 실제 사용(PATH 우선)인지 dt가 아는 경우(default 트리)에만 판정
        return tied.first { $0.metadata["tree"] == defaultTree }
    }

    // MARK: - MCP 참조 판정

    public struct MCPReferenceInfo: Sendable {
        public let details: [String]
        /// 실행 명령을 해석할 수 없는 로컬 MCP가 존재 — 참조를 완전히 판정할 수 없는 상태
        public let hasUnknowable: Bool
    }

    public static func mcpReferenceInfo(packages: [PackageInfo]) -> MCPReferenceInfo {
        var details: [String] = []
        var unknowable = false
        for pkg in packages where pkg.metadata["kind"] == "mcp" {
            if let detail = pkg.metadata["mcpDetail"] {
                details.append(detail)
            } else if pkg.metadata["mcpKind"] != "remote" {
                unknowable = true // 원격은 로컬 패키지를 참조하지 않으므로 제외
            }
        }
        return MCPReferenceInfo(details: details, hasUnknowable: unknowable)
    }

    /// 패키지명·마지막 경로 컴포넌트·**bin 이름들**이 MCP 실행 명령에 등장하면 참조로 본다.
    /// (재검증 반영: bin ≠ 패키지명인 흔한 케이스의 미탐 보강 — bins는 어댑터가 package.json에서 수집)
    public static func isReferencedByMCP(name: String, bins: [String], details: [String]) -> Bool {
        let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
        let needles = ([name, lastComponent] + bins).filter { !$0.isEmpty }
        return details.contains { detail in needles.contains { detail.contains($0) } }
    }

    public static func bins(of pkg: PackageInfo) -> [String] {
        pkg.metadata["bins"]?.split(separator: ",").map(String.init) ?? []
    }

    private static func makeSuggestion(for instance: PackageInfo, keep: PackageInfo,
                                       name: String, mcp: MCPReferenceInfo) -> PruneSuggestion? {
        guard let npmPath = instance.metadata["npmPath"] else { return nil }
        let npm = URL(fileURLWithPath: npmPath)
        let environment = ["PATH": "\(npm.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"]

        let keepTree = keep.metadata["tree"] ?? "다른 트리"
        let evidence: String
        if let keepVersion = keep.current, keepVersion != instance.current {
            evidence = "\(keepTree)에 더 새로운 \(keepVersion)이 있음"
        } else {
            evidence = "\(keepTree)(기본 트리)와 동일 버전 중복"
        }

        var blockReason: String?
        if instance.flags.contains(.runtime) {
            // 현재 npm 어댑터는 runtime 플래그를 세팅하지 않는다 — 향후 플래그 확장 대비 방어선
            blockReason = "런타임은 정리 대상이 아닙니다"
        } else if mcp.hasUnknowable {
            blockReason = "해석할 수 없는 MCP 설정이 있어 참조 여부를 판정할 수 없습니다 — 터미널에서 확인 후 정리하세요"
        } else if isReferencedByMCP(name: name, bins: bins(of: instance), details: mcp.details) {
            // 보수적 차단: MCP가 도구 이름을 쓰는 한, 어느 트리 사본이든 사람이 확인 후 정리
            blockReason = "MCP 서버가 사용 중인 패키지 — 터미널에서 확인 후 정리하세요"
        }

        return PruneSuggestion(
            target: instance,
            evidence: evidence,
            blockReason: blockReason,
            removeCommand: UpdateCommand(executable: npm,
                                         arguments: ["uninstall", "-g", name],
                                         environment: environment),
            restoreCommand: UpdateCommand(executable: npm,
                                          arguments: ["install", "-g", "\(name)@\(instance.current ?? "latest")"],
                                          environment: environment))
    }
}
