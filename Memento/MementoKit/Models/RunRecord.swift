import Foundation

struct RunRecord: Identifiable, Sendable, Codable {
    let id: UUID
    let startDate: Date
    var endDate: Date?
    var status: RunStatus
    var sourcePaths: [String]
    var destinationPath: String
    var itemsMoved: Int
    var itemsCopied: Int
    var itemsSkipped: Int
    var bytesTransferred: Int64
    var duplicatesQuarantined: Int
    var checkpoints: [CheckpointRecord]
    var journalPath: String
    /// Saved copy of the plan, so an interrupted run can be resumed after a relaunch.
    var planPath: String?
    var interruptionReason: String?

    var itemsTotal: Int { itemsMoved + itemsCopied + itemsSkipped }

    enum RunStatus: String, Sendable, Codable {
        case inProgress  = "In Progress"
        case completed   = "Completed"
        case interrupted = "Interrupted"
        case reverted    = "Reverted"
    }

    init(id: UUID = UUID(), sourceURLs: [URL], destinationURL: URL) {
        self.id = id
        self.startDate = Date()
        self.status = .inProgress
        self.sourcePaths = sourceURLs.map(\.path)
        self.destinationPath = destinationURL.path
        self.itemsMoved = 0; self.itemsCopied = 0
        self.itemsSkipped = 0; self.bytesTransferred = 0
        self.duplicatesQuarantined = 0
        self.checkpoints = []
        self.journalPath = ""
    }

    /// Adds the executor's latest checkpoint once; progress snapshots repeat the same token.
    mutating func recordCheckpoint(from progress: ExecutionProgress) {
        let token = progress.lastCheckpointToken
        guard !token.isEmpty, checkpoints.last?.token != token else { return }
        checkpoints.append(CheckpointRecord(
            token: token, itemsCompleted: progress.completed, bytesCompleted: progress.bytesTransferred
        ))
    }
}

struct CheckpointRecord: Identifiable, Sendable, Codable {
    let id: UUID
    let date: Date
    let token: String
    let itemsCompleted: Int
    let bytesCompleted: Int64

    init(token: String, itemsCompleted: Int, bytesCompleted: Int64) {
        self.id = UUID()
        self.date = Date()
        self.token = token
        self.itemsCompleted = itemsCompleted
        self.bytesCompleted = bytesCompleted
    }
}
