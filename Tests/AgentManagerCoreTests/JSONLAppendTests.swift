import XCTest
@testable import AgentManagerCore

/// Locks in the `O_APPEND` guarantee of `JSONLAppend`: the JSONL logs are
/// written by several independent processes at once (app, CLI, daemon), and
/// the old seek-then-write append let concurrent writers land on the same
/// offset and tear each other's lines. Concurrent same-process writers with
/// separate descriptors race the same way, so this reproduces the bug without
/// spawning processes.
final class JSONLAppendTests: XCTestCase {
    func testConcurrentWritersNeverTearLines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-append-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("audit.log.jsonl")

        // Long details make torn lines overwhelmingly likely under the old code.
        let writers = 8
        let perWriter = 200
        let padding = String(repeating: "x", count: 512)
        DispatchQueue.concurrentPerform(iterations: writers) { writer in
            let log = AuditLog(fileURL: file)
            for i in 0..<perWriter {
                log.append(accountID: "w\(writer)", action: "test", ok: true, detail: "\(padding)-\(i)")
            }
        }

        let content = try String(contentsOf: file, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, writers * perWriter, "lost or merged records")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in lines {
            XCTAssertNotNil(
                try? decoder.decode(AuditEvent.self, from: Data(line.utf8)),
                "torn line: \(line.prefix(80))…")
        }
    }

    func testAppendCreatesMissingDirectoryAndFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-append-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("nested").appendingPathComponent("log.jsonl")

        JSONLAppend.appendLine(Data("{\"a\":1}".utf8), to: file)
        JSONLAppend.appendLine(Data("{\"a\":2}".utf8), to: file)

        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(content, "{\"a\":1}\n{\"a\":2}\n")
    }
}
