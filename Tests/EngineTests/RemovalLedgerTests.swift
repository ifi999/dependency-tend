import XCTest
@testable import Engine

final class RemovalLedgerTests: XCTestCase {
    private func makeLedger() -> RemovalLedger {
        RemovalLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("tend-ledger-\(UUID().uuidString)/removal-ledger.json"))
    }

    private func record(id: String = "r1", name: String = "@openai/codex") -> RemovalRecord {
        RemovalRecord(id: id,
                      date: Date(timeIntervalSince1970: 1_750_000_000),
                      packageID: "npmGlobal:pkg:v22.21.1 (nvm):\(name)",
                      name: name,
                      tree: "v22.21.1 (nvm)",
                      version: "0.101.0",
                      restore: UpdateCommand(executable: URL(fileURLWithPath: "/nvm22/bin/npm"),
                                             arguments: ["install", "-g", "\(name)@0.101.0"]))
    }

    func testAppendLoadRoundTrip() throws {
        let ledger = makeLedger()
        XCTAssertTrue(ledger.load().isEmpty) // 파일 없으면 빈 목록

        try ledger.append(record())
        try ledger.append(record(id: "r2", name: "openai-oauth"))
        let loaded = ledger.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].name, "@openai/codex")
        XCTAssertEqual(loaded[0].restore.arguments, ["install", "-g", "@openai/codex@0.101.0"])
    }

    func testRemoveEntry() throws {
        let ledger = makeLedger()
        try ledger.append(record())
        try ledger.append(record(id: "r2", name: "openai-oauth"))
        try ledger.remove(id: "r1")
        XCTAssertEqual(ledger.load().map(\.id), ["r2"])
    }

    func testCorruptFileReturnsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tend-ledger-\(UUID().uuidString)/removal-ledger.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: url)
        XCTAssertTrue(RemovalLedger(fileURL: url).load().isEmpty)
    }
}
