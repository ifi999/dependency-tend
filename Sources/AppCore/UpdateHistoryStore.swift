import Engine
import Foundation

public struct UpdateHistoryStore: Sendable {
    public let fileURL: URL

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dependency-tend/update-history.jsonl")
    }

    public init(fileURL: URL = UpdateHistoryStore.defaultURL()) {
        self.fileURL = fileURL
    }

    public func append(_ entry: UpdateHistoryEntry) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        handle.write(data)
    }

    public func loadLatest(limit: Int = 50) -> [UpdateHistoryEntry] {
        guard limit > 0,
              let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = text.split(separator: "\n").compactMap { line -> UpdateHistoryEntry? in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(UpdateHistoryEntry.self, from: lineData)
        }
        return Array(entries.suffix(limit).reversed())
    }
}
