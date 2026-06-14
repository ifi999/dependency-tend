import Engine

public enum UpdateSourceSummaryPresentation {
    public static func text(for visiblePackages: [PackageInfo]) -> String {
        text(for: visiblePackages, language: .korean)
    }

    public static func text(for visiblePackages: [PackageInfo], language: AppLanguage) -> String {
        let outdatedCount = visiblePackages.filter { $0.status == .outdated }.count
        let unknownCount = visiblePackages.filter {
            $0.status == .unknown && !isInventoryOnly($0)
        }.count
        let inventoryCount = visiblePackages.filter {
            $0.status == .unknown && isInventoryOnly($0)
        }.count
        let highRiskCount = visiblePackages.filter {
            $0.status == .outdated && $0.risk == .high
        }.count

        var parts: [String] = []
        if outdatedCount > 0 {
            parts.append(language == .korean ? "업데이트 \(outdatedCount)" : "Updates \(outdatedCount)")
        }
        if unknownCount > 0 {
            parts.append(language == .korean ? "확인 필요 \(unknownCount)" : "Needs check \(unknownCount)")
        }
        if highRiskCount > 0 {
            parts.append(language == .korean ? "위험 \(highRiskCount)" : "Risky \(highRiskCount)")
        }
        if inventoryCount > 0 {
            parts.append(language == .korean ? "인벤토리 \(inventoryCount)" : "Inventory \(inventoryCount)")
        }
        if parts.isEmpty {
            parts.append(language == .korean ? "최신 \(visiblePackages.count)" : "Current \(visiblePackages.count)")
        }
        return parts.joined(separator: " · ")
    }

    private static func isInventoryOnly(_ pkg: PackageInfo) -> Bool {
        pkg.statusReason == .inventoryOnly || pkg.metadata["kind"] == "mcp"
    }
}
