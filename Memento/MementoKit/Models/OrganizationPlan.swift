import Foundation

struct OrganizationPlan: Identifiable, Sendable, Codable {
    let id: UUID
    let runID: UUID
    var proposedFolders: [PlannedFolder]
    var duplicateSets: [DuplicateSet]
    var needsReviewItems: [MediaItem]
    var screenshotItems: [MediaItem]
    var destinationURL: URL
    var placementMode: PlacementMode
    var sourceURLs: [URL]
    /// Disk read throughput measured during the scan, used to estimate the apply time.
    var measuredBytesPerSecond: Double?

    nonisolated var totalItems: Int { proposedFolders.reduce(0) { $0 + $1.itemCount } }
    nonisolated var totalSize: Int64 { proposedFolders.reduce(0) { $0 + $1.totalSize } }
    nonisolated var byYear: [Int: [PlannedFolder]] {
        Dictionary(grouping: proposedFolders) { folder in
            folder.event.map { Calendar.current.component(.year, from: $0.startDate) } ?? 0
        }
    }

    nonisolated init(id: UUID = UUID(), runID: UUID = UUID(),
         destinationURL: URL, placementMode: PlacementMode, sourceURLs: [URL]) {
        self.id = id; self.runID = runID
        self.proposedFolders = []; self.duplicateSets = []
        self.needsReviewItems = []; self.screenshotItems = []
        self.destinationURL = destinationURL
        self.placementMode = placementMode
        self.sourceURLs = sourceURLs
    }
}

struct PlannedFolder: Identifiable, Sendable, Codable {
    let id: UUID
    var name: String
    var relativePath: String
    var items: [MediaItem]
    var event: MediaEvent?
    var conflicts: [FilenameConflict]

    nonisolated var totalSize: Int64 { items.reduce(0) { $0 + $1.fileSize } }
    nonisolated var itemCount: Int { items.count }

    nonisolated init(id: UUID = UUID(), name: String, relativePath: String,
         items: [MediaItem], event: MediaEvent? = nil) {
        self.id = id; self.name = name
        self.relativePath = relativePath; self.items = items
        self.event = event; self.conflicts = []
    }
}

struct FilenameConflict: Sendable, Codable {
    let originalName: String
    let resolvedName: String
    let reason: ConflictReason
    enum ConflictReason: String, Sendable, Codable { case differentContent, identical }
}

struct DuplicateSet: Identifiable, Sendable, Codable {
    let id: UUID
    let kind: DuplicateKind
    var items: [MediaItem]
    var keeperID: UUID

    nonisolated var keeper: MediaItem?     { items.first { $0.id == keeperID } }
    /// Items the executor moves to quarantine. Empty for kinds that only flag related
    /// photos (bursts, RAW+JPEG, Live Photo) — those are all kept.
    nonisolated var quarantined: [MediaItem] {
        guard kind.quarantinesCopies else { return [] }
        return items.filter { $0.id != keeperID }
    }
    nonisolated var spaceSaved: Int64 { quarantined.reduce(0) { $0 + $1.fileSize } }

    nonisolated init(id: UUID = UUID(), kind: DuplicateKind, items: [MediaItem]) {
        self.id = id; self.kind = kind; self.items = items
        self.keeperID = items.first?.id ?? UUID()
    }
}

enum DuplicateKind: String, Sendable, CaseIterable, Codable {
    case byteIdentical        = "Byte-identical"
    case lowerResolution      = "Lower resolution"
    case rawJpegPair          = "RAW + JPEG pair"
    case livePhotoComponents  = "Live Photo pair"
    case nearIdenticalBurst   = "Near-identical burst"
    case screenshotVsOriginal = "Screenshot"

    /// Whether the non-keeper items of this kind are true redundant copies to quarantine.
    nonisolated var quarantinesCopies: Bool {
        switch self {
        case .byteIdentical, .lowerResolution, .screenshotVsOriginal: true
        case .rawJpegPair, .livePhotoComponents, .nearIdenticalBurst:  false
        }
    }
}

enum PlacementMode: String, Sendable, CaseIterable, Codable, Identifiable {
    case move     = "Move"
    case copy     = "Copy"
    case hardlink = "Hardlink"
    nonisolated var id: String { rawValue }

    nonisolated var tagline: String {
        switch self {
        case .move:     "Fastest, journalled, fully reversible. Default."
        case .copy:     "Safest — originals untouched. Requires extra space."
        case .hardlink: "Zero bytes moved — same volume only."
        }
    }
}
