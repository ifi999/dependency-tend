import Engine

public enum UpdateRequestDecision: Equatable {
    case runImmediately
    case requiresConfirmation(packageID: String)
    case blocked(packageID: String, reason: String)
}

public struct UpdateConfirmationSnapshot: Equatable, Sendable {
    public let packageID: String
    public let current: String?
    public let latest: String?
    public let status: PackageStatus
    public let statusReason: PackageStatusReason?
    public let risk: Risk?
    public let flags: Set<PackageFlag>
    public let metadata: [String: String]

    public init(_ pkg: PackageInfo) {
        packageID = pkg.id
        current = pkg.current
        latest = pkg.latest
        status = pkg.status
        statusReason = pkg.statusReason
        risk = pkg.risk
        flags = pkg.flags
        metadata = pkg.metadata
    }
}

public struct UpdateConfirmationState: Equatable {
    private var snapshot: UpdateConfirmationSnapshot?

    public var packageID: String? {
        snapshot?.packageID
    }

    public init() {
        self.snapshot = nil
    }

    public mutating func request(_ pkg: PackageInfo) -> UpdateRequestDecision {
        switch UpdatePolicy.evaluate(pkg) {
        case .automatic:
            clear()
            return .runImmediately
        case .requiresConfirmation:
            snapshot = UpdateConfirmationSnapshot(pkg)
            return .requiresConfirmation(packageID: pkg.id)
        case .unavailable(let reason):
            clear()
            return .blocked(packageID: pkg.id, reason: reason)
        }
    }

    public func isConfirming(_ pkg: PackageInfo) -> Bool {
        snapshot == UpdateConfirmationSnapshot(pkg)
    }

    public func confirmation(for pkg: PackageInfo) -> UpdateConfirmationSnapshot? {
        isConfirming(pkg) ? snapshot : nil
    }

    public mutating func clear() {
        snapshot = nil
    }
}
