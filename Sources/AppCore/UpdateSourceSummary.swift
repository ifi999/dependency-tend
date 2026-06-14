import Engine

public struct UpdateSourceSummary: Equatable, Sendable {
    public let manager: ManagerID
    public let totalCount: Int
    public let outdatedCount: Int
    public let unknownCount: Int
    public let highRiskCount: Int
    public let safeUpdatableCount: Int

    public init(manager: ManagerID, totalCount: Int, outdatedCount: Int,
                unknownCount: Int, highRiskCount: Int, safeUpdatableCount: Int) {
        self.manager = manager
        self.totalCount = totalCount
        self.outdatedCount = outdatedCount
        self.unknownCount = unknownCount
        self.highRiskCount = highRiskCount
        self.safeUpdatableCount = safeUpdatableCount
    }
}
