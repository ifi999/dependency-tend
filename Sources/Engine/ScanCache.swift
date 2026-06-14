import Foundation

public struct ScanCache: Sendable {
    public let fileURL: URL

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dependency-tend/scan-cache.json")
    }

    public init(fileURL: URL = ScanCache.defaultURL()) {
        self.fileURL = fileURL
    }

    /// 없거나 깨졌으면 nil — 캐시는 best-effort
    public func load() -> ScanResult? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScanResult.self, from: data)
    }

    public func save(_ result: ScanResult) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: fileURL, options: .atomic)
    }
}
