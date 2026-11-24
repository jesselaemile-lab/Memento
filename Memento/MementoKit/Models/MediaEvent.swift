import Foundation

struct MediaEvent: Identifiable, Sendable, Codable {
    let id: UUID
    var name: String
    var startDate: Date
    var endDate: Date
    var items: [MediaItem]
    var locationName: String?
    var evidenceTags: [EvidenceTag]
    var sourceDescription: String

    var year: Int { Calendar.current.component(.year, from: startDate) }
    var itemCount: Int { items.count }
    var totalSize: Int64 { items.reduce(0) { $0 + $1.fileSize } }
    var videoCount: Int { items.filter { $0.mediaType == .video }.count }
    var hasMissingDates: Bool { items.contains { $0.hasMissingEXIF } }

    enum EvidenceTag: String, Sendable, CaseIterable, Codable {
        case timeGap          = "Time gap"
        case gpsRadius        = "GPS radius"
        case faceChange       = "Face change"
        case burstDensity     = "Burst density"
        case sourceFolderName = "Folder name"
        case holiday          = "Holiday"
    }

    nonisolated init(id: UUID = UUID(), name: String, items: [MediaItem]) {
        self.id = id
        self.name = name
        self.items = items
        self.evidenceTags = []
        self.sourceDescription = ""
        let dates = items.compactMap(\.captureDate).sorted()
        self.startDate = dates.first ?? Date()
        self.endDate   = dates.last  ?? Date()
    }
}
