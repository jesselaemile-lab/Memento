import Foundation

// MARK: - Journal entry model

struct JournalEntry: Sendable {
    var runID: String
    var checkpointID: String?
    var sourcePath: String
    var destPath: String?
    var sha256: String?
    var bytes: Int64
    var timestamp: TimeInterval
    var op: OpType
    var status: OpStatus

    enum OpType: String, Codable { case copy, removeSource, quarantine, checkpoint }
    enum OpStatus: String, Codable { case pending, completed, failed, reverted }
}

extension JournalEntry: Codable {
    enum CodingKeys: String, CodingKey {
        case runID, checkpointID, sourcePath, destPath, sha256, bytes, timestamp, op, status
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runID,                   forKey: .runID)
        try c.encodeIfPresent(checkpointID,   forKey: .checkpointID)
        try c.encode(sourcePath,              forKey: .sourcePath)
        try c.encodeIfPresent(destPath,       forKey: .destPath)
        try c.encodeIfPresent(sha256,         forKey: .sha256)
        try c.encode(bytes,                   forKey: .bytes)
        try c.encode(timestamp,               forKey: .timestamp)
        try c.encode(op,                      forKey: .op)
        try c.encode(status,                  forKey: .status)
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        runID        = try c.decode(String.self,       forKey: .runID)
        checkpointID = try c.decodeIfPresent(String.self, forKey: .checkpointID)
        sourcePath   = try c.decode(String.self,       forKey: .sourcePath)
        destPath     = try c.decodeIfPresent(String.self, forKey: .destPath)
        sha256       = try c.decodeIfPresent(String.self, forKey: .sha256)
        bytes        = try c.decode(Int64.self,        forKey: .bytes)
        timestamp    = try c.decode(TimeInterval.self, forKey: .timestamp)
        op           = try c.decode(OpType.self,       forKey: .op)
        status       = try c.decode(OpStatus.self,     forKey: .status)
    }
}

// MARK: - Journal actor

/// Append-only, fsync'd JSONL journal. Every write is durable before the call returns.
actor JournalStore {

    private var fileHandle: FileHandle?
    private(set) var journalURL: URL

    static func makeURL(runID: UUID) throws -> URL {
        let support = try AppDirectories.applicationSupport()
        let dir = support.appendingPathComponent("Memento/Journals", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(runID).jsonl")
    }

    init(url: URL) throws {
        self.journalURL = url
        // createFile would truncate an existing journal — only create when missing, since
        // revert and recovery reopen journals written by earlier runs.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let fh = FileHandle(forWritingAtPath: url.path) else {
            throw JournalError.cannotOpen(url)
        }
        fh.seekToEndOfFile()
        self.fileHandle = fh
    }

    deinit {
        try? fileHandle?.close()
    }

    // MARK: - Write

    func append(_ entry: JournalEntry) throws {
        let data = try JSONEncoder().encode(entry)
        var line = data
        line.append(0x0A)  // newline
        try fileHandle?.write(contentsOf: line)
        fileHandle?.synchronizeFile()  // fsync
    }

    /// Write a checkpoint entry using `token` as the stable checkpoint identifier.
    func writeCheckpoint(runID: UUID, token: String,
                         itemsCompleted: Int, bytesCompleted: Int64) throws {
        let entry = JournalEntry(
            runID: runID.uuidString,
            checkpointID: token,
            sourcePath: "", destPath: nil, sha256: nil,
            bytes: bytesCompleted,
            timestamp: Date().timeIntervalSince1970,
            op: .checkpoint, status: .completed
        )
        try append(entry)
    }

    // MARK: - Read (for revert)

    func readAll() throws -> [JournalEntry] {
        let text = try String(contentsOf: journalURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return text.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { try? decoder.decode(JournalEntry.self, from: Data($0.utf8)) }
    }

    // MARK: - Revert entire run

    func revert() async throws -> (reverted: Int, failed: Int) {
        try revertEntries(try readAll())
    }

    // MARK: - Revert to a specific checkpoint (undoes ops after that token)

    func revert(afterCheckpointToken token: String) async throws -> (reverted: Int, failed: Int) {
        let all = try readAll()
        let start: Int
        if let idx = all.lastIndex(where: { $0.op == .checkpoint && $0.checkpointID == token }) {
            start = idx + 1
        } else {
            start = 0
        }
        return try revertEntries(Array(all[start...]))
    }

    // MARK: - Private helper

    private func revertEntries(_ entries: [JournalEntry]) throws -> (reverted: Int, failed: Int) {
        var reverted = 0; var failed = 0
        let fm = FileManager.default

        for entry in entries.reversed() {
            guard entry.status == .completed else { continue }
            switch entry.op {
            case .copy, .removeSource:
                guard let dest = entry.destPath else { continue }
                let src = URL(fileURLWithPath: entry.sourcePath)
                let dst = URL(fileURLWithPath: dest)
                do {
                    if fm.fileExists(atPath: dest) {
                        try fm.copyItem(at: dst, to: src)
                        try fm.removeItem(at: dst)
                    }
                    reverted += 1
                } catch { failed += 1 }
            case .quarantine:
                guard let dest = entry.destPath else { continue }
                let src = URL(fileURLWithPath: entry.sourcePath)
                let dst = URL(fileURLWithPath: dest)
                do {
                    if fm.fileExists(atPath: dest) {
                        try fm.moveItem(at: dst, to: src)
                    }
                    reverted += 1
                } catch { failed += 1 }
            case .checkpoint:
                break
            }
        }
        return (reverted, failed)
    }

    enum JournalError: Error {
        case cannotOpen(URL)
    }
}
