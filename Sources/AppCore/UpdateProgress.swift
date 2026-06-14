public enum UpdateProgressMode: String, Equatable, Sendable {
    case single
    case bulk
}

public struct UpdateProgress: Equatable, Sendable {
    public let currentPackageID: String
    public let currentPackageName: String
    public let completed: Int
    public let total: Int
    public let mode: UpdateProgressMode

    public init(currentPackageID: String, currentPackageName: String,
                completed: Int, total: Int, mode: UpdateProgressMode) {
        self.currentPackageID = currentPackageID
        self.currentPackageName = currentPackageName
        self.completed = completed
        self.total = max(total, 1)
        self.mode = mode
    }
}

public struct UpdateProgressPresentation: Equatable, Sendable {
    public let title: String
    public let countText: String
    public let showsLinearProgress: Bool
}

public extension UpdateProgress {
    var presentation: UpdateProgressPresentation {
        presentation(language: .korean)
    }

    func presentation(language: AppLanguage) -> UpdateProgressPresentation {
        let active = min(completed + 1, total)
        let title: String
        switch language {
        case .korean:
            title = "\(currentPackageName) 업데이트 중"
        case .english:
            title = "\(currentPackageName) updating"
        }
        return UpdateProgressPresentation(title: title,
                                          countText: "\(active)/\(total)",
                                          showsLinearProgress: false)
    }
}
