import Testing
import Foundation
import CoreLocation
import CoreGraphics
import ImageIO
@testable import Memento

// MARK: - Helpers

private func makeItem(
    url: URL? = nil,
    fileSize: Int64 = 1_000_000,
    mediaType: MediaType = .photo,
    captureDate: Date? = nil,
    sha256: String? = nil,
    perceptualHash: UInt64? = nil,
    dimensions: CGSize? = nil,
    location: CLLocationCoordinate2D? = nil,
    isScreenshot: Bool = false
) -> MediaItem {
    var item = MediaItem(
        id: UUID(),
        url: url ?? URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg"),
        fileSize: fileSize,
        mediaType: mediaType
    )
    item.captureDate   = captureDate
    item.sha256        = sha256
    item.perceptualHash = perceptualHash
    item.dimensions    = dimensions
    item.location      = location
    item.isScreenshot  = isScreenshot
    return item
}

private func dateAt(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day; c.hour = hour
    return Calendar.current.date(from: c)!
}

// MARK: - EventGrouper tests

@Suite("EventGrouper")
@MainActor
struct EventGrouperTests {

    let rules = GroupingRules.default
    var grouper: EventGrouper { EventGrouper(rules: rules) }

    @Test("Single item produces one event")
    func singleItem() {
        let item = makeItem(captureDate: dateAt(2024, 6, 1))
        let events = grouper.group(items: [item])
        #expect(events.count == 1)
        #expect(events[0].items.count == 1)
    }

    @Test("Time gap over 18 h splits into two events")
    func timeGapSplit() {
        var rules2 = GroupingRules.default
        rules2.minimumItemsPerGroup = 1  // disable small-group merge to isolate time-gap splitting
        let grouper2 = EventGrouper(rules: rules2)

        let base = dateAt(2024, 6, 1, 10)
        let items = [
            makeItem(captureDate: base),
            makeItem(captureDate: base.addingTimeInterval(3600)),       // +1 h → same group
            makeItem(captureDate: base.addingTimeInterval(20 * 3600))   // 19 h after previous item → new event
        ]
        let events = grouper2.group(items: items)
        #expect(events.count == 2)
        guard events.count == 2 else { return }
        #expect(events[0].items.count == 2)
        #expect(events[1].items.count == 1)
    }

    @Test("Time gap under 18 h stays in same event")
    func timeGapNoSplit() {
        let base = dateAt(2024, 6, 1, 0)
        let items = (0..<5).map { i in
            makeItem(captureDate: base.addingTimeInterval(Double(i) * 3600))
        }
        let events = grouper.group(items: items)
        #expect(events.count == 1)
    }

    @Test("GPS jump over 25 km splits into two events")
    func gpsJumpSplit() {
        var rules2 = GroupingRules.default
        rules2.minimumItemsPerGroup = 1  // disable small-group merge for this test
        let grouper2 = EventGrouper(rules: rules2)

        let base = dateAt(2024, 6, 1, 12)
        var itemA = makeItem(captureDate: base)
        var itemB = makeItem(captureDate: base.addingTimeInterval(1800))
        var itemC = makeItem(captureDate: base.addingTimeInterval(3600))

        // A and B are in Paris, C is in New York (~5500 km away)
        itemA.location = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        itemB.location = CLLocationCoordinate2D(latitude: 48.8600, longitude: 2.3522)
        itemC.location = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)

        let events = grouper2.group(items: [itemA, itemB, itemC])
        #expect(events.count == 2)
    }

    @Test("Distant small groups are not glued into one months-long event")
    func noCrossMonthEvents() {
        // July trip of 10 photos, then a few stray photos in Oct, Nov and Jan.
        var items: [MediaItem] = (0..<10).map { makeItem(captureDate: dateAt(2018, 7, 26, $0)) }
        items += [makeItem(captureDate: dateAt(2018, 10, 3)), makeItem(captureDate: dateAt(2018, 11, 12)),
                  makeItem(captureDate: dateAt(2019, 1, 6))]
        let events = grouper.group(items: items)

        for e in events {
            #expect(Calendar.current.isDate(e.startDate, equalTo: e.endDate, toGranularity: .month),
                    "event \(e.name) spans months")
        }
        #expect(events.first?.items.count == 10)

        var rules = GroupingRules.default
        rules.structureMode = .yearEvent
        let paths = Set(PlanBuilder(rules: rules).build(
            events: events, allItems: items, destinationURL: URL(fileURLWithPath: "/tmp/o"),
            placementMode: .copy, sourceURLs: []).proposedFolders.map(\.relativePath))
        // Stragglers sit loose in their own month folders.
        #expect(paths.contains { $0.hasPrefix("2018/10-") && $0.split(separator: "/").count == 2 })
        #expect(paths.contains { $0.hasPrefix("2019/01-") })
    }

    @Test("Small groups below minimum merge into neighbour")
    func smallGroupMerge() {
        var rules2 = GroupingRules.default
        rules2.minimumItemsPerGroup = 5
        rules2.timeGapHours = 1
        let grouper2 = EventGrouper(rules: rules2)

        let base = dateAt(2024, 6, 1, 0)
        // First group: 1 item (below minimum) — should merge into next
        // Second group: 6 items (above minimum)
        var items: [MediaItem] = [makeItem(captureDate: base)]
        for i in 0..<6 {
            items.append(makeItem(captureDate: base.addingTimeInterval(Double(2 + i) * 3600)))
        }
        let events = grouper2.group(items: items)
        // The single-item first group should merge into the 6-item group
        #expect(events.count == 1)
        #expect(events[0].items.count == 7)
    }
}

// MARK: - PlanBuilder tests

@Suite("PlanBuilder")
@MainActor
struct PlanBuilderTests {

    private func build(_ events: [MediaEvent], rules: GroupingRules) -> OrganizationPlan {
        PlanBuilder(rules: rules).build(
            events: events,
            allItems: events.flatMap(\.items),
            destinationURL: URL(fileURLWithPath: "/tmp/out"),
            placementMode: .copy,
            sourceURLs: []
        )
    }

    @Test("Default structure is Year › Month")
    func defaultIsYearMonth() {
        #expect(GroupingRules.default.structureMode == .yearMonth)
    }

    @Test("Year › Month: events in the same month share one 'yyyy/MM-Month' folder")
    func yearMonthBucketsByMonth() {
        let a = MediaEvent(name: "April 2", items: [makeItem(captureDate: dateAt(2023, 4, 2))])
        let b = MediaEvent(name: "April 20", items: [makeItem(captureDate: dateAt(2023, 4, 20))])
        let c = MediaEvent(name: "Christmas", items: [makeItem(captureDate: dateAt(2026, 12, 25))])

        let plan = build([a, b, c], rules: .default)

        #expect(plan.proposedFolders.count == 2)
        #expect(plan.proposedFolders[0].relativePath.hasPrefix("2023/04-"))
        #expect(plan.proposedFolders[0].itemCount == 2)
        #expect(plan.proposedFolders[1].relativePath.hasPrefix("2026/12-"))
    }

    @Test("Events with the same folder path merge instead of creating '(2)' folders")
    func samePathEventsMerge() {
        var rules = GroupingRules.default
        rules.structureMode = .yearEvent
        rules.minimumItemsPerGroup = 1
        let a = MediaEvent(name: "Sunrise", items: [makeItem(captureDate: dateAt(2026, 3, 2))])
        let b = MediaEvent(name: "Mount Dora", items: [makeItem(captureDate: dateAt(2026, 3, 9))])
        let c = MediaEvent(name: "Sunrise", items: [makeItem(captureDate: dateAt(2026, 3, 20))])

        let plan = build([a, b, c], rules: rules)

        #expect(plan.proposedFolders.map(\.relativePath) == ["2026/03-March/Sunrise", "2026/03-March/Mount Dora"])
        #expect(plan.proposedFolders[0].itemCount == 2)
        #expect(!plan.proposedFolders.contains { $0.relativePath.contains("(2)") })
    }

    @Test("Events named after the old album go straight into the month folder")
    func albumNamedEventsAtMonthLevel() {
        var rules = GroupingRules.default
        rules.structureMode = .yearEvent
        rules.minimumItemsPerGroup = 1
        var album = MediaEvent(name: "Sep25-Mar26", items: [makeItem(captureDate: dateAt(2026, 3, 2))])
        album.evidenceTags = [.sourceFolderName]
        let holiday = MediaEvent(name: "Christmas", items: [makeItem(captureDate: dateAt(2025, 12, 25))])

        #expect(build([album, holiday], rules: rules).proposedFolders.map(\.relativePath).sorted()
                == ["2025/12-December/Christmas", "2026/03-March"])

        rules.reuseSourceFolderNames = true
        #expect(build([album], rules: rules).proposedFolders.map(\.relativePath) == ["2026/03-March/Sep25-Mar26"])
    }

    @Test("Old saved name format is upgraded so the year/month isn't repeated")
    func oldTemplateMigrated() throws {
        let json = #"{"namingTemplate":"{yyyy}-{mm} {event}","structureMode":"Year › Event"}"#
        let rules = try JSONDecoder().decode(GroupingRules.self, from: Data(json.utf8))
        #expect(rules.namingTemplate == "{event}")
        #expect(rules.structureMode == .yearEvent)
    }

    @Test("Undated items stay out of folders and wait in Needs review")
    func undatedItemsExcluded() {
        let dated = makeItem(captureDate: dateAt(2024, 6, 1))
        let undated = makeItem()
        let event = MediaEvent(name: "June", items: [dated, undated])

        let plan = build([event], rules: .default)

        #expect(plan.proposedFolders.flatMap(\.items).map(\.id) == [dated.id])
        #expect(plan.needsReviewItems.map(\.id) == [undated.id])
    }

    @Test("Year › Event: event nested under its year and month")
    func yearEventUsesEventName() {
        var rules = GroupingRules.default
        rules.structureMode = .yearEvent
        rules.minimumItemsPerGroup = 1
        let event = MediaEvent(name: "Christmas", items: [makeItem(captureDate: dateAt(2026, 12, 25))])

        let plan = build([event], rules: rules)

        #expect(plan.proposedFolders.map(\.relativePath) == ["2026/12-December/Christmas"])
    }
}

// MARK: - Executor tests

/// Collects progress snapshots from the executor's @Sendable callback.
private final class ProgressLog: @unchecked Sendable {
    var snapshots: [ExecutionProgress] = []
    var last: ExecutionProgress { snapshots.last ?? ExecutionProgress() }
}

/// Builds a throwaway source/destination tree on disk for end-to-end executor tests.
private struct TempLibrary {
    let root: URL
    var source: URL { root.appendingPathComponent("src") }
    var dest: URL   { root.appendingPathComponent("dst") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("memento-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    }

    func file(_ name: String, contents: String) throws -> MediaItem {
        let url = source.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        var item = MediaItem(id: UUID(), url: url, fileSize: Int64(contents.utf8.count), mediaType: .photo)
        item.captureDate = dateAt(2024, 6, 1)
        return item
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Executor", .serialized)
@MainActor
struct ExecutorTests {

    @Test("Quarantine journal records the renamed destination when a name collides")
    func quarantineJournalUsesActualPath() async throws {
        let lib = try TempLibrary(); defer { lib.cleanup() }
        let keeper = try lib.file("IMG_1.jpg", contents: "same bytes")
        let copy   = try lib.file("IMG_1 copy.jpg", contents: "same bytes")
        // Pre-existing file in quarantine forces a "(2)" rename.
        let qDir = lib.dest.appendingPathComponent("_Duplicates (quarantine)")
        try FileManager.default.createDirectory(at: qDir, withIntermediateDirectories: true)
        try Data("older".utf8).write(to: qDir.appendingPathComponent("IMG_1 copy.jpg"))

        var set = DuplicateSet(kind: .byteIdentical, items: [keeper, copy])
        set.keeperID = keeper.id
        var plan = OrganizationPlan(destinationURL: lib.dest, placementMode: .move, sourceURLs: [lib.source])
        plan.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [keeper])]
        plan.duplicateSets = [set]

        let journalURL = lib.root.appendingPathComponent("journal.jsonl")
        let journal = try JournalStore(url: journalURL)
        try await Executor().execute(plan: plan, journal: journal) { _ in }

        let q = try #require(try await journal.readAll().first { $0.op == .quarantine })
        let loggedDest = try #require(q.destPath)
        #expect(loggedDest.hasSuffix("IMG_1 copy (2).jpg"))
        #expect(FileManager.default.fileExists(atPath: loggedDest))
    }

    @Test("Checkpoints are journaled and surfaced in progress; RunRecord records each once")
    func checkpointsRecorded() async throws {
        let lib = try TempLibrary(); defer { lib.cleanup() }
        let a = try lib.file("A.jpg", contents: "a"), b = try lib.file("B.jpg", contents: "b")
        var plan = OrganizationPlan(destinationURL: lib.dest, placementMode: .move, sourceURLs: [lib.source])
        plan.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [a, b])]

        let journal = try JournalStore(url: lib.root.appendingPathComponent("journal.jsonl"))
        var record = RunRecord(id: plan.runID, sourceURLs: [lib.source], destinationURL: lib.dest)
        let log = ProgressLog()
        // Interval 0 → a checkpoint after every file.
        try await Executor(checkpointInterval: 0).execute(plan: plan, journal: journal) { log.snapshots.append($0) }
        for p in log.snapshots { record.recordCheckpoint(from: p) }

        let checkpoints = try await journal.readAll().filter { $0.op == .checkpoint }
        #expect(checkpoints.count == 2)
        #expect(record.checkpoints.count == 2)
        #expect(record.checkpoints.map(\.token) == checkpoints.compactMap(\.checkpointID))
    }

    @Test("Resume skips files an earlier attempt already moved and finishes the rest")
    func resumeSkipsCompleted() async throws {
        let lib = try TempLibrary(); defer { lib.cleanup() }
        let a = try lib.file("A.jpg", contents: "aaa"), b = try lib.file("B.jpg", contents: "bbb")
        let folder = PlannedFolder(name: "June", relativePath: "2024/06-June", items: [a, b])
        var full = OrganizationPlan(destinationURL: lib.dest, placementMode: .move, sourceURLs: [lib.source])
        full.proposedFolders = [folder]
        // First attempt "crashed" after A: run a plan containing only A.
        var partial = full
        partial.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [a])]

        let journalURL = lib.root.appendingPathComponent("journal.jsonl")
        try await Executor().execute(plan: partial, journal: try JournalStore(url: journalURL)) { _ in }

        let journal = try JournalStore(url: journalURL)
        let state = Executor.ResumeState(entries: try await journal.readAll())
        let log = ProgressLog()
        try await Executor().execute(plan: full, journal: journal, resuming: state) { log.snapshots.append($0) }

        let copies = try await journal.readAll().filter { $0.op == .copy && $0.status == .completed }
        #expect(copies.count == 2)                                   // A was not copied twice
        #expect(copies.filter { $0.sourcePath == a.url.path }.count == 1)
        #expect(log.last.completed == 2)
        #expect(FileManager.default.fileExists(atPath: lib.dest.appendingPathComponent("2024/06-June/A.jpg").path))
        #expect(FileManager.default.fileExists(atPath: lib.dest.appendingPathComponent("2024/06-June/B.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: b.url.path))
    }

    @Test("Resume releases a source whose copy was verified but not yet removed")
    func resumeReleasesUnremovedSource() async throws {
        let lib = try TempLibrary(); defer { lib.cleanup() }
        let a = try lib.file("A.jpg", contents: "aaa")
        var plan = OrganizationPlan(destinationURL: lib.dest, placementMode: .move, sourceURLs: [lib.source])
        plan.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [a])]

        // Simulate the crash window between "copy journaled" and "source removed".
        let destDir = lib.dest.appendingPathComponent("2024/06-June")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("A.jpg")
        try FileManager.default.copyItem(at: a.url, to: dest)
        let hash = try await FileHasher().sha256(of: dest)
        let journal = try JournalStore(url: lib.root.appendingPathComponent("journal.jsonl"))
        try await journal.append(JournalEntry(
            runID: plan.runID.uuidString, checkpointID: nil, sourcePath: a.url.path, destPath: dest.path,
            sha256: hash, bytes: 3, timestamp: 0, op: .copy, status: .completed))

        let state = Executor.ResumeState(entries: try await journal.readAll())
        try await Executor().execute(plan: plan, journal: journal, resuming: state) { _ in }

        #expect(!FileManager.default.fileExists(atPath: a.url.path))
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try await journal.readAll().contains { $0.op == .removeSource && $0.sourcePath == a.url.path })
    }

    @Test("A plan round-trips through JSON so it can be resumed after a relaunch")
    func planCodable() throws {
        var item = makeItem(captureDate: dateAt(2024, 6, 1), sha256: "abc",
                            location: CLLocationCoordinate2D(latitude: 1, longitude: 2))
        item.dimensions = CGSize(width: 10, height: 20)
        var plan = OrganizationPlan(destinationURL: URL(fileURLWithPath: "/tmp/out"), placementMode: .move, sourceURLs: [])
        plan.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [item], event: MediaEvent(name: "June", items: [item]))]
        plan.duplicateSets = [DuplicateSet(kind: .byteIdentical, items: [item])]

        let back = try JSONDecoder().decode(OrganizationPlan.self, from: JSONEncoder().encode(plan))
        #expect(back.runID == plan.runID)
        #expect(back.proposedFolders.first?.items.first?.id == item.id)
        #expect(back.proposedFolders.first?.items.first?.location?.longitude == 2)
        #expect(back.proposedFolders.first?.items.first?.dimensions == CGSize(width: 10, height: 20))
        #expect(back.duplicateSets.first?.kind == .byteIdentical)
    }

    @Test("Move within one volume is a rename: no copy pass, still journaled as copy + removeSource")
    func sameVolumeMoveIsRename() async throws {
        let lib = try TempLibrary(); defer { lib.cleanup() }
        let a = try lib.file("A.jpg", contents: "aaa")
        var plan = OrganizationPlan(destinationURL: lib.dest, placementMode: .move, sourceURLs: [lib.source])
        plan.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [a])]
        let journal = try JournalStore(url: lib.root.appendingPathComponent("journal.jsonl"))

        #expect(VolumeCheck.sameVolume(lib.source, lib.dest))
        try await Executor().execute(plan: plan, journal: journal) { _ in }

        let ops = try await journal.readAll().map(\.op)
        #expect(ops == [.copy, .removeSource])
        #expect(!FileManager.default.fileExists(atPath: a.url.path))
        #expect(FileManager.default.fileExists(atPath: lib.dest.appendingPathComponent("2024/06-June/A.jpg").path))
    }

    @Test("Plan estimate scales with size for copies and is near-instant for same-volume moves")
    @MainActor
    func planEstimate() throws {
        let lib = try TempLibrary(); defer { lib.cleanup() }
        var item = makeItem(url: lib.source.appendingPathComponent("A.jpg"), fileSize: 3_000_000_000, captureDate: dateAt(2024, 6, 1))
        item.sha256 = "x"
        var plan = OrganizationPlan(destinationURL: lib.dest, placementMode: .copy, sourceURLs: [lib.source])
        plan.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [item])]
        plan.measuredBytesPerSecond = 100_000_000   // 100 MB/s → 3 GB × 3 passes ≈ 90 s

        #expect(PlanViewModel(plan: plan).estimatedDuration == "about 2 min")

        plan.placementMode = .move                   // same temp volume → rename
        #expect(PlanViewModel(plan: plan).estimatedDuration == "a few seconds")

        #expect(PlanViewModel.formatEstimate(0.4) == "a few seconds")
        #expect(PlanViewModel.formatEstimate(42) == "about 45 sec")
        #expect(PlanViewModel.formatEstimate(3700) == "about 1 hr 2 min")
    }

    @Test("Existing destination folders are appended to; same-name files are never overwritten")
    func appendsIntoExistingFoldersWithoutOverwriting() async throws {
        let lib = try TempLibrary(); defer { lib.cleanup() }
        // A library that already has a December folder with two photos in it.
        let dec = lib.dest.appendingPathComponent("2026/12-December")
        try FileManager.default.createDirectory(at: dec, withIntermediateDirectories: true)
        try Data("existing other photo".utf8).write(to: dec.appendingPathComponent("IMG_0001.heic"))
        try Data("untouched".utf8).write(to: dec.appendingPathComponent("IMG_0002.heic"))

        // Incoming: same name but different bytes, plus a brand-new file.
        let clash = try lib.file("IMG_0001.heic", contents: "new different photo")
        let fresh = try lib.file("IMG_0003.heic", contents: "fresh")
        var plan = OrganizationPlan(destinationURL: lib.dest, placementMode: .move, sourceURLs: [lib.source])
        plan.proposedFolders = [PlannedFolder(name: "12-December", relativePath: "2026/12-December", items: [clash, fresh])]

        try await Executor().execute(plan: plan, journal: try JournalStore(url: lib.root.appendingPathComponent("j.jsonl"))) { _ in }

        let names = try FileManager.default.contentsOfDirectory(atPath: dec.path).sorted()
        #expect(names == ["IMG_0001 (2).heic", "IMG_0001.heic", "IMG_0002.heic", "IMG_0003.heic"])
        // The pre-existing file kept its original bytes.
        #expect(try String(contentsOf: dec.appendingPathComponent("IMG_0001.heic"), encoding: .utf8) == "existing other photo")
        #expect(try String(contentsOf: dec.appendingPathComponent("IMG_0001 (2).heic"), encoding: .utf8) == "new different photo")
    }

    @Test("A file already in the destination with identical bytes is not duplicated (Move → quarantine, Copy → skip)")
    func identicalExistingFileNotDuplicated() async throws {
        for mode in [PlacementMode.move, .copy] {
            let lib = try TempLibrary(); defer { lib.cleanup() }
            let dec = lib.dest.appendingPathComponent("2026/12-December")
            try FileManager.default.createDirectory(at: dec, withIntermediateDirectories: true)
            try Data("same bytes".utf8).write(to: dec.appendingPathComponent("IMG_0001.heic"))
            let same = try lib.file("IMG_0001.heic", contents: "same bytes")

            var plan = OrganizationPlan(destinationURL: lib.dest, placementMode: mode, sourceURLs: [lib.source])
            plan.proposedFolders = [PlannedFolder(name: "12-December", relativePath: "2026/12-December", items: [same])]
            let log = ProgressLog()
            try await Executor().execute(plan: plan, journal: try JournalStore(url: lib.root.appendingPathComponent("j.jsonl"))) { log.snapshots.append($0) }

            #expect(try FileManager.default.contentsOfDirectory(atPath: dec.path) == ["IMG_0001.heic"], "mode \(mode)")
            #expect(log.last.alreadyPresent == 1)
            #expect(log.last.failed == 0)
            let sourceStillThere = FileManager.default.fileExists(atPath: same.url.path)
            if mode == .move {
                #expect(!sourceStillThere)
                #expect(FileManager.default.fileExists(atPath: lib.dest.appendingPathComponent("_Duplicates (quarantine)/IMG_0001.heic").path))
                #expect(log.last.quarantined == 1)
            } else {
                #expect(sourceStillThere)
            }
        }
    }

    @Test("Revert through a freshly opened journal restores moved and quarantined files")
    func revertRestoresFiles() async throws {
        let lib = try TempLibrary(); defer { lib.cleanup() }
        let keeper = try lib.file("A.jpg", contents: "same")
        let copy   = try lib.file("B.jpg", contents: "same")
        var set = DuplicateSet(kind: .byteIdentical, items: [keeper, copy])
        set.keeperID = keeper.id
        var plan = OrganizationPlan(destinationURL: lib.dest, placementMode: .move, sourceURLs: [lib.source])
        plan.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [keeper])]
        plan.duplicateSets = [set]

        let journalURL = lib.root.appendingPathComponent("journal.jsonl")
        try await Executor().execute(plan: plan, journal: try JournalStore(url: journalURL)) { _ in }
        #expect(!FileManager.default.fileExists(atPath: keeper.url.path))
        #expect(!FileManager.default.fileExists(atPath: copy.url.path))

        // Same as the History screen: a new store instance on the existing journal.
        let result = try await JournalStore(url: journalURL).revert()
        #expect(result.failed == 0)
        #expect(FileManager.default.fileExists(atPath: keeper.url.path))
        #expect(FileManager.default.fileExists(atPath: copy.url.path))
    }
}

// MARK: - MediaScanner tests

@Suite("MediaScanner")
@MainActor
struct MediaScannerTests {

    @Test("Date Created is read exactly as Finder shows it")
    func fallsBackToDateCreated() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memento-dates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("IMG_9.jpg")
        try Data("x".utf8).write(to: url)
        let created = dateAt(2023, 10, 14, 9), modified = dateAt(2025, 3, 1, 9)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)

        var items: [MediaItem] = []
        for try await item in await MediaScanner().scan(sourceURL: dir, onProgress: { _ in }) { items.append(item) }

        #expect(items.first?.captureDate == created)
        #expect(items.first?.fileCreatedDate == created)
        #expect(MediaScanner.fileCreatedDate(created: modified, modified: created) == modified)
        #expect(GroupingRules.default.dateBasis == .dateTaken)
    }

    @Test("IMG_4601 case: created Oct 7 2023, modified Dec 21 2024 → 2023/10-October")
    func screenshotCase() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("memento-4601-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("src")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        // Real JPEG with a DateTimeOriginal that disagrees with Date Created.
        let url = src.appendingPathComponent("IMG_4601.jpeg")
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:12:21 14:47:00"]] as CFDictionary)
        CGImageDestinationFinalize(dest)
        var c = DateComponents(); c.year = 2023; c.month = 10; c.day = 7; c.hour = 8; c.minute = 27
        var m = DateComponents(); m.year = 2024; m.month = 12; m.day = 21; m.hour = 14; m.minute = 47
        try fm.setAttributes([.creationDate: Calendar.current.date(from: c)!,
                              .modificationDate: Calendar.current.date(from: m)!], ofItemAtPath: url.path)

        var rules = GroupingRules.default
        rules.enableLocationReading = false
        rules.dateBasis = .dateCreated
        let vm = ScanViewModel()
        let plan: OrganizationPlan = await withCheckedContinuation { cont in
            vm.start(sourceURLs: [src], destinationURL: root.appendingPathComponent("dst"),
                     placementMode: .copy, rules: rules) { cont.resume(returning: $0) }
        }
        #expect(plan.proposedFolders.map(\.relativePath) == ["2023/10-October"])
    }

    @Test("EXIF time honours the photo's own UTC offset")
    func exifOffset() {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let d = MetadataReader.exifDate("2023:10:31 23:30:00", offset: "+00:00", parser: parser)
        #expect(d == ISO8601DateFormatter().date(from: "2023-10-31T23:30:00Z"))
    }

    @Test("Photos only skips standalone videos but keeps Live Photo clips")
    func photosOnlyFilter() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memento-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["IMG_1.heic", "IMG_1.mov", "IMG_2.jpg", "clip.mp4"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        var opts = MediaScanner.ScanOptions()
        opts.mediaFilter = .photosOnly
        var names: [String] = []
        for try await item in await MediaScanner().scan(sourceURL: dir, options: opts, onProgress: { _ in }) {
            names.append(item.filename)
        }

        #expect(Set(names) == ["IMG_1.heic", "IMG_1.mov", "IMG_2.jpg"])

        opts.mediaFilter = .videosOnly
        names = []
        for try await item in await MediaScanner().scan(sourceURL: dir, options: opts, onProgress: { _ in }) {
            names.append(item.filename)
        }
        #expect(Set(names) == ["IMG_1.mov", "clip.mp4"])
    }
}

// MARK: - LibraryStore tests

@Suite("LibraryStore")
@MainActor
struct LibraryStoreTests {

    @Test("Folders written with destination paths load back after reopening the database")
    func roundTrip() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memento-lib-\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }

        var item = makeItem(url: URL(fileURLWithPath: "/dst/2026/12-December/IMG_1.jpg"),
                            captureDate: dateAt(2026, 12, 25),
                            location: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.42))
        item.dimensions = CGSize(width: 4000, height: 3000)
        let store = try LibraryStore(url: url)
        try await store.insertItems([item], eventName: "12-December", relativePath: "2026/12-December")

        let reopened = try LibraryStore(url: url)
        let folders = try await reopened.loadFolders()
        #expect(folders.count == 1)
        #expect(folders[0].relativePath == "2026/12-December")
        #expect(folders[0].items.first?.url.path == "/dst/2026/12-December/IMG_1.jpg")
        #expect(folders[0].items.first?.location?.latitude == 37.77)
        #expect(folders[0].items.first?.dimensions == CGSize(width: 4000, height: 3000))

        try await reopened.deleteItems(atPaths: ["/dst/2026/12-December/IMG_1.jpg"])
        #expect(try await reopened.loadFolders().isEmpty)
    }
}

// MARK: - AppViewModel helpers

@Suite("AppViewModel helpers")
@MainActor
struct AppViewModelHelperTests {

    @Test("Quarantine badge counts files recursively, not folders")
    func quarantineCount() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memento-q-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("sub/b.jpg"))

        #expect(AppViewModel.countFiles(in: dir) == 2)
        #expect(AppViewModel.countFiles(in: dir.appendingPathComponent("missing")) == 0)
    }
}

// MARK: - PlanViewModel tests

@Suite("PlanViewModel")
@MainActor
struct PlanViewModelTests {

    @Test("Resolving review items files them by date and clears the review list")
    func resolveReviewItemsByDate() {
        let undated = makeItem()
        var plan = OrganizationPlan(destinationURL: URL(fileURLWithPath: "/tmp/out"), placementMode: .move, sourceURLs: [])
        plan.needsReviewItems = [undated]
        let vm = PlanViewModel(plan: plan)

        vm.resolveReviewItems([undated], date: dateAt(2024, 6, 15), folderName: "")

        #expect(vm.plan.needsReviewItems.isEmpty)
        #expect(vm.plan.proposedFolders.count == 1)
        #expect(vm.plan.proposedFolders[0].relativePath.hasPrefix("2024/06-"))
        #expect(vm.plan.proposedFolders[0].items.first?.captureDate == dateAt(2024, 6, 15))
        #expect(vm.plan.proposedFolders[0].items.first?.dateSource == .userProvided)
    }

    @Test("Resolving an already-placed item into a named folder moves it out of its old folder")
    func resolveReviewItemsMovesBetweenFolders() {
        var guessed = makeItem(captureDate: dateAt(2024, 1, 1))
        guessed.hasMissingEXIF = true
        let other = makeItem(captureDate: dateAt(2024, 1, 2))
        var plan = OrganizationPlan(destinationURL: URL(fileURLWithPath: "/tmp/out"), placementMode: .move, sourceURLs: [])
        plan.proposedFolders = [PlannedFolder(name: "01-January", relativePath: "2024/01-January", items: [guessed, other])]
        plan.needsReviewItems = [guessed]
        let vm = PlanViewModel(plan: plan)

        vm.resolveReviewItems([guessed], date: dateAt(2023, 8, 10), folderName: "Beach trip")

        let paths = vm.plan.proposedFolders.map(\.relativePath)
        #expect(paths.contains("2023/Beach trip"))
        #expect(vm.plan.proposedFolders.first { $0.relativePath == "2024/01-January" }?.items.map(\.id) == [other.id])
        let all = vm.plan.proposedFolders.flatMap(\.items).map(\.id)
        #expect(Set(all).count == all.count)
    }

    @Test("'Highest resolution' immediately keeps the larger copy and re-routes the folder")
    func highestResRule() {
        var small = makeItem(captureDate: dateAt(2024, 6, 1), dimensions: CGSize(width: 1000, height: 750))
        small.sha256 = "a"
        let big = makeItem(captureDate: dateAt(2024, 6, 2), dimensions: CGSize(width: 4000, height: 3000))
        var set = DuplicateSet(kind: .lowerResolution, items: [small, big])
        set.keeperID = small.id
        var plan = OrganizationPlan(destinationURL: URL(fileURLWithPath: "/tmp/out"), placementMode: .move, sourceURLs: [])
        plan.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [small])]
        plan.duplicateSets = [set]

        let vm = PlanViewModel(plan: plan)
        vm.applyKeeperRule(.highestRes)

        #expect(vm.plan.duplicateSets[0].keeperID == big.id)
        #expect(vm.plan.proposedFolders[0].items.map(\.id) == [big.id])
        #expect(vm.plan.duplicateSets[0].quarantined.map(\.id) == [small.id])
    }

    @Test("Changing the keeper swaps it into the folder and quarantines the old keeper")
    func keeperChangeReroutes() {
        let a = makeItem(captureDate: dateAt(2024, 6, 1), sha256: "same")
        let b = makeItem(captureDate: dateAt(2024, 6, 2), sha256: "same")
        var set = DuplicateSet(kind: .byteIdentical, items: [a, b])
        set.keeperID = a.id

        // The plan was built with only the keeper (a) in a folder.
        var plan = OrganizationPlan(destinationURL: URL(fileURLWithPath: "/tmp/out"), placementMode: .move, sourceURLs: [])
        plan.proposedFolders = [PlannedFolder(name: "June", relativePath: "2024/06-June", items: [a])]
        plan.duplicateSets = [set]

        let vm = PlanViewModel(plan: plan)
        vm.setKeeperRule(for: set, keeperID: b.id)

        #expect(vm.plan.proposedFolders[0].items.map(\.id) == [b.id])
        #expect(vm.plan.duplicateSets[0].quarantined.map(\.id) == [a.id])
        // No file is scheduled twice
        let scheduled = vm.plan.proposedFolders.flatMap(\.items).map(\.id) + vm.plan.duplicateSets.flatMap(\.quarantined).map(\.id)
        #expect(Set(scheduled).count == scheduled.count)
    }
}

// MARK: - People tests

@Suite("People")
@MainActor
struct PeopleTests {

    private func face(_ item: MediaItem, size: CGFloat, embedding: [Float]? = nil) -> DetectedFace {
        DetectedFace(itemID: item.id, boundingBox: CGRect(x: 0.1, y: 0.1, width: size, height: size), embedding: embedding)
    }

    @Test("Group photo goes to the named person with the largest face")
    func largestNamedFaceWins() {
        let photo = makeItem(captureDate: dateAt(2026, 12, 25))
        let jesse = FaceCluster(name: "Jesse", faces: [face(photo, size: 0.2)], sampleItems: [photo])
        let anna  = FaceCluster(name: "Anna",  faces: [face(photo, size: 0.4)], sampleItems: [photo])
        let stranger = FaceCluster(faces: [face(photo, size: 0.6)], sampleItems: [photo])

        let map = PeopleAssigner.personByItem(clusters: [jesse, anna, stranger], items: [photo])

        #expect(map[photo.id] == "Anna")   // unnamed stranger's larger face is ignored
    }

    @Test("Live Photo video follows its photo's person")
    func companionFollowsPrimary() {
        var still = makeItem(captureDate: dateAt(2026, 12, 25))
        let video = makeItem(mediaType: .video, captureDate: dateAt(2026, 12, 25))
        still.pairedItemID = video.id
        let jesse = FaceCluster(name: "Jesse", faces: [face(still, size: 0.3)], sampleItems: [still])

        let map = PeopleAssigner.personByItem(clusters: [jesse], items: [still, video])

        #expect(map[video.id] == "Jesse")
    }

    @Test("Similar face embeddings cluster together, different ones don't")
    func clustersByEmbedding() async {
        let a = makeItem(), b = makeItem(), c = makeItem()
        let results: [UUID: FaceDetectionResult] = [
            a.id: FaceDetectionResult(itemID: a.id, faces: [face(a, size: 0.3, embedding: [1, 0, 0])]),
            b.id: FaceDetectionResult(itemID: b.id, faces: [face(b, size: 0.3, embedding: [0.99, 0.1, 0])]),
            c.id: FaceDetectionResult(itemID: c.id, faces: [face(c, size: 0.3, embedding: [0, 0, 1])]),
        ]

        let clusters = await FaceClusterer().cluster(items: [a, b, c], faceResults: results, matchDistance: 0.5)

        #expect(clusters.count == 2)
        #expect(clusters[0].totalItemCount == 2)
    }

    @Test("A known named person seeds clustering so returning faces keep their name")
    func knownPeopleKeepNames() async throws {
        let old = makeItem(), new = makeItem()
        let jesse = FaceCluster(name: "Jesse", faces: [face(old, size: 0.3, embedding: [1, 0, 0])], sampleItems: [old])
        let results = [new.id: FaceDetectionResult(itemID: new.id, faces: [face(new, size: 0.3, embedding: [0.98, 0.15, 0])])]

        let clusters = await FaceClusterer().cluster(items: [new], faceResults: results, matchDistance: 0.5, knownPeople: [jesse])

        #expect(clusters.count == 1)
        #expect(clusters[0].id == jesse.id)
        #expect(clusters[0].name == "Jesse")
        #expect(clusters[0].faces.count == 2)
    }

    @Test("PersonRecord round-trips through JSON")
    func personRecordCodable() throws {
        let item = makeItem()
        let cluster = FaceCluster(name: "Anna", faces: [face(item, size: 0.2, embedding: [0, 1, 0])], sampleItems: [item])
        let data = try JSONEncoder().encode([PersonRecord(cluster: cluster)])
        let back = try JSONDecoder().decode([PersonRecord].self, from: data).map(\.cluster)
        #expect(back.first?.name == "Anna")
        #expect(back.first?.id == cluster.id)
        #expect(back.first?.faces.first?.embedding == [0, 1, 0])
        #expect(back.first?.sampleItems.first?.url == item.url)
    }

    @Test("People mode: Person › Year › Month, unnamed photos to _Other photos")
    func peopleYearMonthPaths() {
        var rules = GroupingRules.default
        rules.structureMode = .people
        let p1 = makeItem(captureDate: dateAt(2026, 12, 25))
        let p2 = makeItem(captureDate: dateAt(2026, 12, 26))
        let event = MediaEvent(name: "Christmas", items: [p1, p2])

        let plan = PlanBuilder(rules: rules).build(
            events: [event], allItems: [p1, p2],
            destinationURL: URL(fileURLWithPath: "/tmp/out"), placementMode: .copy, sourceURLs: [],
            personByItem: [p1.id: "Jesse"]
        )

        let paths = plan.proposedFolders.map(\.relativePath)
        #expect(paths.count == 2)
        #expect(paths.contains { $0.hasPrefix("Jesse/2026/12-") })
        #expect(paths.contains { $0.hasPrefix("_Other photos/2026/12-") })
    }

    @Test("People mode: Person › Year › Event and Person › Place")
    func peopleEventAndPlacePaths() {
        var rules = GroupingRules.default
        rules.structureMode = .people
        rules.minimumItemsPerGroup = 1
        let p = makeItem(captureDate: dateAt(2026, 12, 25))
        var event = MediaEvent(name: "Christmas", items: [p])
        event.locationName = "San Francisco"
        let build = { (r: GroupingRules) in
            PlanBuilder(rules: r).build(
                events: [event], allItems: [p],
                destinationURL: URL(fileURLWithPath: "/tmp/out"), placementMode: .copy, sourceURLs: [],
                personByItem: [p.id: "Jesse"]
            ).proposedFolders.map(\.relativePath)
        }

        rules.peopleSubStructure = .yearEvent
        #expect(build(rules) == ["Jesse/2026/12-December/Christmas"])
        rules.peopleSubStructure = .place
        #expect(build(rules) == ["Jesse/San Francisco"])
    }
}

// MARK: - DuplicateClassifier tests

@Suite("DuplicateClassifier")
@MainActor
struct DuplicateClassifierTests {

    let classifier = DuplicateClassifier()

    @Test("Byte-identical: two items with same SHA-256 produce one set")
    func byteIdentical() {
        let hash = "abc123"
        let older = makeItem(captureDate: dateAt(2024, 1, 1), sha256: hash)
        let newer = makeItem(captureDate: dateAt(2024, 6, 1), sha256: hash)
        let result = classifier.classify(items: [older, newer])
        #expect(result.byteIdenticalSets.count == 1)
        let set = result.byteIdenticalSets[0]
        #expect(set.items.count == 2)
        // Keeper should be the older one
        #expect(set.keeperID == older.id)
    }

    @Test("Three byte-identical items: two quarantined, oldest kept")
    func byteIdenticalThree() {
        let hash = "deadbeef"
        let a = makeItem(captureDate: dateAt(2024, 1, 1), sha256: hash)
        let b = makeItem(captureDate: dateAt(2024, 3, 1), sha256: hash)
        let c = makeItem(captureDate: dateAt(2024, 6, 1), sha256: hash)
        let result = classifier.classify(items: [b, c, a])
        let set = result.byteIdenticalSets[0]
        #expect(set.keeperID == a.id)
        #expect(set.quarantined.count == 2)
    }

    @Test("Unique SHA-256: no byte-identical duplicates")
    func noByteIdentical() {
        let items = [
            makeItem(sha256: "aaa"), makeItem(sha256: "bbb"), makeItem(sha256: "ccc")
        ]
        let result = classifier.classify(items: items)
        #expect(result.byteIdenticalSets.isEmpty)
    }

    @Test("RAW + JPEG pair: detected as pair, not duplicate")
    func rawJpegPair() throws {
        let dir = URL(fileURLWithPath: "/tmp/memento-test-rawjpeg-\(UUID().uuidString)")
        let rawURL  = dir.appendingPathComponent("IMG_1234.arw")
        let jpegURL = dir.appendingPathComponent("IMG_1234.jpg")
        let raw  = makeItem(url: rawURL,  mediaType: .rawPhoto)
        let jpeg = makeItem(url: jpegURL, mediaType: .photo)
        let result = classifier.classify(items: [raw, jpeg])
        #expect(result.rawJpegPairs.count == 1)
        #expect(result.byteIdenticalSets.isEmpty)  // should NOT be a duplicate
        #expect(result.rawJpegPairs[0].primary.mediaType == .rawPhoto)
    }

    @Test("Live Photo pair: .HEIC + .MOV detected as pair, not duplicate")
    func livePhotoPair() {
        let heicURL = URL(fileURLWithPath: "/tmp/IMG_5678.heic")
        let movURL  = URL(fileURLWithPath: "/tmp/IMG_5678.mov")
        let heic = makeItem(url: heicURL, mediaType: .photo)
        let mov  = makeItem(url: movURL,  mediaType: .video)
        let result = classifier.classify(items: [heic, mov])
        #expect(result.livePhotoPairs.count == 1)
        #expect(result.byteIdenticalSets.isEmpty)
    }

    @Test("Lower resolution: same pHash, different dimensions — larger kept")
    func lowerResolution() {
        let pHash: UInt64 = 0b1010101010101010
        let hi  = makeItem(perceptualHash: pHash, dimensions: CGSize(width: 4000, height: 3000))
        let lo  = makeItem(perceptualHash: pHash, dimensions: CGSize(width: 800,  height: 600))
        let result = classifier.classify(items: [lo, hi])
        #expect(result.lowerResolutionSets.count == 1)
        let set = result.lowerResolutionSets[0]
        #expect(set.keeperID == hi.id)
        #expect(set.quarantined.map(\.id).contains(lo.id))
    }

    @Test("Near-identical burst: same pHash + within 2 s → burst group")
    func nearIdenticalBurst() {
        let pHash: UInt64 = 0xFF00FF00FF00FF00
        let base = dateAt(2024, 8, 15, 14)
        let a = makeItem(captureDate: base, perceptualHash: pHash)
        let b = makeItem(captureDate: base.addingTimeInterval(0.5), perceptualHash: pHash)
        let c = makeItem(captureDate: base.addingTimeInterval(1.0), perceptualHash: pHash)
        let result = classifier.classify(items: [a, b, c])
        #expect(result.burstGroups.count == 1)
        #expect(result.burstGroups[0].items.count == 3)
    }

    @Test("Burst shots are all kept — nothing quarantined")
    func burstNotQuarantined() {
        let t = dateAt(2024, 6, 1, 12)
        let a = makeItem(captureDate: t, perceptualHash: 0xABCD, dimensions: CGSize(width: 4000, height: 3000))
        let b = makeItem(captureDate: t.addingTimeInterval(1), perceptualHash: 0xABCD, dimensions: CGSize(width: 4000, height: 3000))
        let result = DuplicateClassifier().classify(items: [a, b])
        #expect(result.burstGroups.count == 1)
        #expect(result.burstGroups[0].quarantined.isEmpty)
        #expect(result.burstGroups[0].spaceSaved == 0)
    }

    @Test("Byte-identical copies ARE quarantined")
    func byteIdenticalQuarantined() {
        let a = makeItem(captureDate: dateAt(2024, 6, 1), sha256: "same")
        let b = makeItem(captureDate: dateAt(2024, 6, 2), sha256: "same")
        let result = DuplicateClassifier().classify(items: [a, b])
        #expect(result.byteIdenticalSets.first?.quarantined.count == 1)
    }

    @Test("Burst: items more than 2 s apart are NOT a burst")
    func notABurst() {
        let pHash: UInt64 = 0xFF00FF00FF00FF00
        let base = dateAt(2024, 8, 15, 14)
        let a = makeItem(captureDate: base, perceptualHash: pHash)
        let b = makeItem(captureDate: base.addingTimeInterval(5), perceptualHash: pHash)  // 5 s > 2 s
        let result = classifier.classify(items: [a, b])
        #expect(result.burstGroups.isEmpty)
    }

    @Test("Screenshots flagged")
    func screenshots() {
        let screenshot = makeItem(isScreenshot: true)
        let regular    = makeItem(isScreenshot: false)
        let result = classifier.classify(items: [screenshot, regular])
        #expect(result.screenshotIDs.contains(screenshot.id))
        #expect(!result.screenshotIDs.contains(regular.id))
    }
}

// MARK: - Journal revert tests

@Suite("JournalStore")
@MainActor
struct JournalStoreTests {

    @Test("Append and read back entries")
    func appendAndRead() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("memento-journal-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("test.jsonl")
        let store = try JournalStore(url: url)

        let entry = JournalEntry(
            runID: UUID().uuidString, checkpointID: nil,
            sourcePath: "/src/photo.jpg", destPath: "/dst/photo.jpg",
            sha256: "abc123", bytes: 1_234_567,
            timestamp: Date().timeIntervalSince1970,
            op: .copy, status: .completed
        )
        try await store.append(entry)

        let all = try await store.readAll()
        #expect(all.count == 1)
        #expect(all[0].sourcePath == "/src/photo.jpg")
        #expect(all[0].sha256 == "abc123")
    }

    @Test("Reopening an existing journal keeps its entries (revert must not truncate)")
    func reopenPreservesEntries() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memento-reopen-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try JournalStore(url: url)
        try await first.writeCheckpoint(runID: UUID(), token: "cp-1", itemsCompleted: 1, bytesCompleted: 1)

        let reopened = try JournalStore(url: url)
        #expect(try await reopened.readAll().count == 1)
    }

    @Test("Checkpoint written and readable")
    func checkpoint() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memento-cp-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try JournalStore(url: url)
        let runID = UUID()
        try await store.writeCheckpoint(runID: runID, token: "cp-42-999",
                                        itemsCompleted: 42, bytesCompleted: 100_000)

        let all = try await store.readAll()
        #expect(all.count == 1)
        #expect(all[0].op == .checkpoint)
        #expect(all[0].runID == runID.uuidString)
    }
}


// MARK: - Live fixture (end-to-end on real HEIC files)

/// Runs the entire pipeline on a copy of ~/Desktop/MementoTest/Source. Skipped when the
/// fixture isn't present so CI/other machines aren't affected.
@Suite("Live fixture", .serialized)
@MainActor
struct LiveFixtureTests {

    private static var fixture: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/MementoTest/Source")
    }

    @Test("Scan → plan → execute → library on real files")
    func fullPipeline() async throws {
        let fm = FileManager.default
        try #require(fm.fileExists(atPath: Self.fixture.path), "Fixture missing — skip")

        // Work on a private copy so the Desktop fixture stays intact for manual testing.
        let root = fm.temporaryDirectory.appendingPathComponent("memento-live-\(UUID().uuidString)", isDirectory: true)
        let src = root.appendingPathComponent("Source"), dst = root.appendingPathComponent("Destination")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.copyItem(at: Self.fixture, to: src)
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        var rules = GroupingRules.default
        rules.enableLocationReading = false   // no network in tests

        // 1. Scan
        let scanVM = ScanViewModel()
        let plan: OrganizationPlan = await withCheckedContinuation { cont in
            scanVM.start(sourceURLs: [src], destinationURL: dst, placementMode: .move, rules: rules) { plan in
                cont.resume(returning: plan)
            }
        }
        #expect(scanVM.phase == .ready)
        #expect(scanVM.foundItems == 10)

        // 2. Plan: Year › Month folders ("yyyy/MM-Month"); one byte-identical duplicate.
        // The wallpaper HEICs carry embedded capture dates, so exact months come from EXIF.
        let paths = plan.proposedFolders.map(\.relativePath).sorted()
        #expect(paths.count >= 3, "got \(paths)")
        #expect(paths.allSatisfy { $0.range(of: #"^\d{4}/\d{2}-\p{L}+$"#, options: .regularExpression) != nil }, "got \(paths)")
        #expect(plan.totalItems == 9)
        let dupes = plan.duplicateSets.filter { $0.kind == .byteIdentical }
        #expect(dupes.count == 1)
        #expect(dupes.first?.quarantined.count == 1)
        // Filesystem-dated items are flagged for review but still placed
        #expect(plan.needsReviewItems.isEmpty)

        // 3. Execute
        let journal = try JournalStore(url: root.appendingPathComponent("journal.jsonl"))
        let log = ProgressLog()
        try await Executor().execute(plan: plan, journal: journal) { log.snapshots.append($0) }
        #expect(log.last.completed == 9)
        #expect(log.last.failed == 0)
        #expect(log.last.quarantined == 1)

        let organized = try fm.subpathsOfDirectory(atPath: dst.path).filter { $0.hasSuffix(".heic") }
        #expect(organized.count == 10, "\(organized)")
        #expect(organized.contains { $0.hasPrefix("_Duplicates (quarantine)/") })
        let remaining = try fm.subpathsOfDirectory(atPath: src.path).filter { $0.hasSuffix(".heic") }
        #expect(remaining.isEmpty, "sources left behind: \(remaining)")

        // 4. Library index reflects destination paths
        let dbURL = root.appendingPathComponent("library.db")
        let store = try LibraryStore(url: dbURL)
        let entries = try await journal.readAll()
        var destBySource: [String: String] = [:]
        for e in entries where e.op == .copy && e.status == .completed { destBySource[e.sourcePath] = e.destPath }
        for folder in plan.proposedFolders {
            let moved = folder.items.compactMap { i in destBySource[i.url.path].map { i.relocated(to: URL(fileURLWithPath: $0)) } }
            try await store.insertItems(moved, eventName: folder.name, relativePath: folder.relativePath)
        }
        let folders = try await store.loadFolders()
        #expect(folders.count == plan.proposedFolders.count)
        #expect(folders.flatMap(\.items).allSatisfy { fm.fileExists(atPath: $0.url.path) })

        // 5. Revert brings everything back
        let result = try await JournalStore(url: journal.journalURL).revert()
        #expect(result.failed == 0)
        let restored = try fm.subpathsOfDirectory(atPath: src.path).filter { $0.hasSuffix(".heic") }
        #expect(restored.count == 10)
    }
}
