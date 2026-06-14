import Foundation

/// 삭제 기록 한 건 — 복원 명령을 버전까지 박제해 둔다 (정리 스펙 §2-④)
public struct RemovalRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let date: Date
    public let packageID: String
    public let name: String
    public let tree: String?
    public let version: String?
    /// 원클릭 복구용 — 삭제 당시 버전으로 고정된 설치 명령
    public let restore: UpdateCommand

    public init(id: String, date: Date, packageID: String, name: String,
                tree: String?, version: String?, restore: UpdateCommand) {
        self.id = id
        self.date = date
        self.packageID = packageID
        self.name = name
        self.tree = tree
        self.version = version
        self.restore = restore
    }
}

/// 복구 장부 — 디스크 영속 (best-effort load, 깨지면 빈 목록)
public struct RemovalLedger: Sendable {
    public let fileURL: URL

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dependency-tend/removal-ledger.json")
    }

    public init(fileURL: URL = RemovalLedger.defaultURL()) {
        self.fileURL = fileURL
    }

    public func load() -> [RemovalRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RemovalRecord].self, from: data)) ?? []
    }

    public func append(_ record: RemovalRecord) throws {
        try save(load() + [record])
    }

    public func remove(id: String) throws {
        try save(load().filter { $0.id != id })
    }

    private func save(_ records: [RemovalRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: fileURL, options: .atomic)
    }
}
