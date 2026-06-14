import Foundation

public actor PackageScanner {
    private let adapters: [any PackageManagerAdapter]
    private let now: @Sendable () -> Date

    public init(adapters: [any PackageManagerAdapter],
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.adapters = adapters
        self.now = now
    }

    public func scanAll() async -> ScanResult {
        await scanGroup(adapters)
    }

    /// 업데이트 후 해당 매니저만 재스캔할 때 사용
    public func scan(only manager: ManagerID) async -> ScanResult {
        await scanGroup(adapters.filter { $0.id == manager })
    }

    private func scanGroup(_ targets: [any PackageManagerAdapter]) async -> ScanResult {
        var packages: [PackageInfo] = []
        var advisories: [ManagerAdvisory] = []
        var errors: [ScanError] = []
        var sourceHealth: [SourceHealth] = []

        await withTaskGroup(of: (ManagerID, Result<AdapterScan, Error>).self) { group in
            for adapter in targets {
                guard adapter.isAvailable() else {
                    sourceHealth.append(SourceHealth(manager: adapter.id,
                                                     availability: .unavailable,
                                                     packageCount: 0,
                                                     message: "도구를 찾을 수 없습니다"))
                    continue
                }
                group.addTask { [clock = now] in
                    do { return (adapter.id, .success(try await adapter.scan(now: clock()))) }
                    catch { return (adapter.id, .failure(error)) }
                }
            }
            for await (managerID, result) in group {
                switch result {
                case .success(let scan):
                    let classified = scan.packages.map(RiskClassifier.classify)
                    packages.append(contentsOf: classified)
                    advisories.append(contentsOf: scan.advisories)
                    sourceHealth.append(SourceHealth(manager: managerID,
                                                     availability: classified.isEmpty ? .empty : .available,
                                                     packageCount: classified.count))
                case .failure(let error):
                    // UI에 그대로 노출되므로 LocalizedError 우선 (raw enum 표기 방지)
                    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    errors.append(ScanError(manager: managerID, message: message))
                    sourceHealth.append(SourceHealth(manager: managerID,
                                                     availability: .failed,
                                                     packageCount: 0,
                                                     message: message))
                }
            }
        }
        packages.sort { ($0.manager.rawValue, $0.name) < ($1.manager.rawValue, $1.name) }
        sourceHealth.sort { Self.managerOrder($0.manager) < Self.managerOrder($1.manager) }
        return ScanResult(packages: packages, advisories: advisories, errors: errors,
                          sourceHealth: sourceHealth, timestamp: now())
    }

    private static func managerOrder(_ manager: ManagerID) -> Int {
        ManagerID.allCases.firstIndex(of: manager) ?? Int.max
    }
}
