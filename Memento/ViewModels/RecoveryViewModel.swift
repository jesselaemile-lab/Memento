import Foundation

struct RecoverySummary: Sendable {
    var runID: String
    var sourceDescription: String
    var interruptionDate: Date?
    var interruptionReason: String?
    var confirmedMoved: Int
    var copiedUnverified: Int
    var failed: Int
    var quarantined: Int
    var lastCheckpointToken: String?
    var isSourceVolumeMissing: Bool

    var totalMovedFiles: Int { confirmedMoved + copiedUnverified }
}

@Observable
@MainActor
final class RecoveryViewModel {

    enum VerifyState { case idle, running, done }

    var summary: RecoverySummary?
    var verifyState: VerifyState = .idle
    var verifyDone: Int = 0
    var verifyTotal: Int = 0
    var revertResult: (reverted: Int, failed: Int)?
    var isReverting: Bool = false
    var errorMessage: String?

    private var runRecord: RunRecord?

    // MARK: - Load

    func prepare(record: RunRecord) async {
        runRecord = record
        let journalURL = URL(fileURLWithPath: record.journalPath)

        let sourcePath = record.sourcePaths.first ?? ""
        let sourceExists = sourcePath.isEmpty || FileManager.default.fileExists(atPath: sourcePath)

        guard !record.journalPath.isEmpty, FileManager.default.fileExists(atPath: journalURL.path) else {
            summary = RecoverySummary(
                runID: record.id.uuidString,
                sourceDescription: sourcePath,
                interruptionDate: record.endDate ?? record.startDate,
                interruptionReason: record.interruptionReason ?? "Journal file not found.",
                confirmedMoved: 0, copiedUnverified: 0, failed: 0, quarantined: 0,
                lastCheckpointToken: nil, isSourceVolumeMissing: !sourceExists
            )
            return
        }

        do {
            let store = try JournalStore(url: journalURL)
            let entries = try await store.readAll()

            let copies      = entries.filter { $0.op == .copy     && $0.status == .completed }
            let removedPaths = Set(entries.filter { $0.op == .removeSource && $0.status == .completed }.map(\.sourcePath))
            let confirmed   = copies.filter {  removedPaths.contains($0.sourcePath) }.count
            let unverified  = copies.filter { !removedPaths.contains($0.sourcePath) }.count
            let failedCount = entries.filter { $0.status == .failed }.count
            let qCount      = entries.filter { $0.op == .quarantine && $0.status == .completed }.count
            let lastCP      = entries.filter { $0.op == .checkpoint }.last

            summary = RecoverySummary(
                runID: record.id.uuidString,
                sourceDescription: sourcePath,
                interruptionDate: record.endDate ?? record.startDate,
                interruptionReason: record.interruptionReason,
                confirmedMoved: confirmed,
                copiedUnverified: unverified,
                failed: failedCount,
                quarantined: qCount,
                lastCheckpointToken: lastCP?.checkpointID,
                isSourceVolumeMissing: !sourceExists
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Verify unconfirmed copies

    func verifyUnconfirmed() async {
        guard let record = runRecord else { return }
        let journalURL = URL(fileURLWithPath: record.journalPath)
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }

        verifyState = .running
        verifyDone  = 0

        do {
            let store    = try JournalStore(url: journalURL)
            let entries  = try await store.readAll()
            let copies   = entries.filter { $0.op == .copy && $0.status == .completed }
            let removed  = Set(entries.filter { $0.op == .removeSource }.map(\.sourcePath))
            let pending  = copies.filter { !removed.contains($0.sourcePath) }
            verifyTotal  = pending.count

            let hasher = FileHasher()
            for entry in pending {
                if let destPath = entry.destPath {
                    let _ = try? await hasher.sha256(of: URL(fileURLWithPath: destPath))
                }
                verifyDone += 1
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        verifyState = .done
    }

    // MARK: - Revert

    func revertRun() async {
        guard let record = runRecord else { return }
        let journalURL = URL(fileURLWithPath: record.journalPath)
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            errorMessage = "Journal file not found — cannot revert."
            return
        }
        isReverting = true
        do {
            let store = try JournalStore(url: journalURL)
            revertResult = try await store.revert()
        } catch {
            errorMessage = error.localizedDescription
        }
        isReverting = false
    }
}
