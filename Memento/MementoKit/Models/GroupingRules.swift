import Foundation

struct GroupingRules: Sendable, Codable {
    var timeGapHours: Double           = 18
    var locationGapKilometers: Double  = 25
    var minimumItemsPerGroup: Int      = 8
    var recognizeHolidays: Bool        = true
    /// Keep old album folder names as event subfolders; off = file them at month level.
    var reuseSourceFolderNames: Bool   = false
    var namingTemplate: String         = "{event}"
    var structureMode: StructureMode   = .yearMonth
    var peopleSubStructure: PeopleSubStructure = .yearMonth
    /// Max feature-print distance for two faces to count as the same person (lower = stricter).
    var faceMatchDistance: Double      = 0.6
    var includeScreenshots: Bool       = false
    var followSymlinks: Bool           = false
    var includeSidecars: Bool          = true
    /// Kept for saved-rules compatibility; faces now only run in People mode.
    var enableFaceClustering: Bool     = false
    var enableLocationReading: Bool    = true
    var scanNestedSubfolders: Bool     = true
    /// Which media to organize; videos can be skipped to save time and destination space.
    var mediaFilter: MediaFilter       = .photosAndVideos
    /// Which date places a file into Year › Month.
    var dateBasis: DateBasis           = .dateTaken

    enum StructureMode: String, Sendable, Codable, CaseIterable, Identifiable {
        case yearMonth = "Year › Month"
        case yearEvent = "Year › Event"
        case eventOnly = "Event only"
        case people    = "People"
        case place     = "Place"
        var id: String { rawValue }
    }

    enum DateBasis: String, Sendable, Codable, CaseIterable, Identifiable {
        case dateTaken   = "Date taken"
        case dateCreated = "Date created"
        var id: String { rawValue }
    }

    enum MediaFilter: String, Sendable, Codable, CaseIterable, Identifiable {
        case photosAndVideos = "Photos & videos"
        case photosOnly      = "Photos only"
        case videosOnly      = "Videos only"
        var id: String { rawValue }
    }

    /// Folder layout inside each person's folder when `structureMode == .people`.
    enum PeopleSubStructure: String, Sendable, Codable, CaseIterable, Identifiable {
        case yearMonth = "Year › Month"
        case yearEvent = "Year › Event"
        case place     = "Place"
        var id: String { rawValue }
    }

    /// Face detection is slow on large libraries, so it only runs when People mode needs it.
    nonisolated var needsFaceDetection: Bool { structureMode == .people }

    static let `default` = GroupingRules()

    init() {}

    // Decode each key independently so rules saved by older versions (missing newer keys)
    // still load, with defaults filling the gaps instead of discarding the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GroupingRules()
        timeGapHours           = (try? c.decode(Double.self, forKey: .timeGapHours)) ?? d.timeGapHours
        locationGapKilometers  = (try? c.decode(Double.self, forKey: .locationGapKilometers)) ?? d.locationGapKilometers
        minimumItemsPerGroup   = (try? c.decode(Int.self, forKey: .minimumItemsPerGroup)) ?? d.minimumItemsPerGroup
        recognizeHolidays      = (try? c.decode(Bool.self, forKey: .recognizeHolidays)) ?? d.recognizeHolidays
        reuseSourceFolderNames = (try? c.decode(Bool.self, forKey: .reuseSourceFolderNames)) ?? d.reuseSourceFolderNames
        namingTemplate         = (try? c.decode(String.self, forKey: .namingTemplate)) ?? d.namingTemplate
        // The old default repeated the year/month the folder path now provides
        // ("2023/10-October/2023-10 Roosevelt"); upgrade it to the new default.
        if namingTemplate == "{yyyy}-{mm} {event}" { namingTemplate = d.namingTemplate }
        structureMode          = (try? c.decode(StructureMode.self, forKey: .structureMode)) ?? d.structureMode
        peopleSubStructure     = (try? c.decode(PeopleSubStructure.self, forKey: .peopleSubStructure)) ?? d.peopleSubStructure
        faceMatchDistance      = (try? c.decode(Double.self, forKey: .faceMatchDistance)) ?? d.faceMatchDistance
        includeScreenshots     = (try? c.decode(Bool.self, forKey: .includeScreenshots)) ?? d.includeScreenshots
        followSymlinks         = (try? c.decode(Bool.self, forKey: .followSymlinks)) ?? d.followSymlinks
        includeSidecars        = (try? c.decode(Bool.self, forKey: .includeSidecars)) ?? d.includeSidecars
        enableFaceClustering   = (try? c.decode(Bool.self, forKey: .enableFaceClustering)) ?? d.enableFaceClustering
        enableLocationReading  = (try? c.decode(Bool.self, forKey: .enableLocationReading)) ?? d.enableLocationReading
        scanNestedSubfolders   = (try? c.decode(Bool.self, forKey: .scanNestedSubfolders)) ?? d.scanNestedSubfolders
        mediaFilter            = (try? c.decode(MediaFilter.self, forKey: .mediaFilter)) ?? d.mediaFilter
        dateBasis              = (try? c.decode(DateBasis.self, forKey: .dateBasis)) ?? d.dateBasis
    }
}
