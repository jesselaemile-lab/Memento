import Foundation
import SwiftUI

// MARK: - Navigation destinations

enum SidebarSection: String, Hashable, CaseIterable {
    case timeline, folders, people, places
    case needsReview, duplicates, quarantine, interrupted
    case newRun, scanning, plan, history, rules

    var displayName: String {
        switch self {
        case .timeline:    "Timeline"
        case .folders:     "Folders"
        case .people:      "People"
        case .places:      "Places"
        case .needsReview: "Needs review"
        case .duplicates:  "Duplicates"
        case .quarantine:  "Quarantine"
        case .interrupted: "Interrupted run"
        case .newRun:      "New run"
        case .scanning:    "Scanning"
        case .plan:        "Plan"
        case .history:     "History"
        case .rules:       "Rules"
        }
    }

    var systemIcon: String {
        switch self {
        case .timeline:    "calendar"
        case .folders:     "folder"
        case .people:      "person.2"
        case .places:      "map"
        case .needsReview: "questionmark.circle"
        case .duplicates:  "doc.on.doc"
        case .quarantine:  "archivebox"
        case .interrupted: "exclamationmark.triangle"
        case .newRun:      "plus.circle"
        case .scanning:    "magnifyingglass"
        case .plan:        "checklist"
        case .history:     "clock.arrow.circlepath"
        case .rules:       "slider.horizontal.3"
        }
    }
}

// MARK: - AppViewModel

@Observable
@MainActor
final class AppViewModel {
    var selectedSection: SidebarSection = .timeline

    var scanVM: ScanViewModel?
    var planVM: PlanViewModel?
    var activeExecutionProgress: ExecutionProgress?
    var isExecuting: Bool = false

    var organizedFolders: [PlannedFolder] = []
    var runHistory: [RunRecord] = []
    var rules: GroupingRules = .default {
        didSet { saveRules() }
    }

    var needsReviewItems: [MediaItem] = []
    var duplicateSets: [DuplicateSet] = []
    /// Files currently sitting in the quarantine folder (drives the sidebar badge).
    var quarantineCount: Int = 0
    var interruptedRun: RunRecord? = nil
    var faceClusters: [FaceCluster] = []
    /// True between a People-mode scan finishing and the user continuing to the plan.
    var isAwaitingPeopleNames: Bool = false
    var libraryStore: LibraryStore?

    var needsYouCount: Int { needsReviewItems.count + duplicateSets.count }
    /// Duplicate sets as the plan currently has them (keeper changes live in the plan).
    var currentDuplicateSets: [DuplicateSet] { planVM?.plan.duplicateSets ?? duplicateSets }
    var isRunInFlight: Bool { scanVM != nil || isExecuting }
    /// Show the top progress bar only while something is actually running — once the scan
    /// reaches "Ready" the Plan screen has its own header.
    var showsProgressBanner: Bool {
        isExecuting || (scanVM.map { $0.phase != .ready && $0.phase != .cancelled } ?? false)
    }

    var quarantineURL: URL? {
        guard let record = runHistory.first(where: { $0.status == .completed }) else { return nil }
        return URL(fileURLWithPath: record.destinationPath)
            .appendingPathComponent("_Duplicates (quarantine)")
    }

    /// Recounts quarantined files on disk. Cheap enough to call after any run, revert or trash.
    func refreshQuarantineCount() async {
        guard let dir = quarantineURL else { quarantineCount = 0; return }
        quarantineCount = await Task.detached(priority: .utility) { Self.countFiles(in: dir) }.value
    }

    nonisolated static func countFiles(in dir: URL) -> Int {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return 0 }
        var n = 0
        while let url = e.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory != true { n += 1 }
        }
        return n
    }

    private var runStoreURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("memento-runs.json")

    private let sleepBlocker = SleepBlocker()

    // MARK: - Setup (call from AppShell.onAppear)

    func setup() {
        loadRules()
        guard let url = try? Self.makeRunStoreURL() else { return }
        runStoreURL = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([RunRecord].self, from: data) {
            runHistory = saved
            if let hit = saved.first(where: { $0.status == .inProgress || $0.status == .interrupted }) {
                interruptedRun = hit
                selectedSection = .interrupted
            }
        }
        if let storeURL = try? LibraryStore.makeURL() {
            libraryStore = try? LibraryStore(url: storeURL)
        }
        loadPeople()
        Task { await reloadLibrary(); await refreshQuarantineCount() }
    }

    /// Refreshes the Timeline / Folders / Places source from the on-disk index.
    private func reloadLibrary() async {
        guard let store = libraryStore else { return }
        organizedFolders = (try? await store.loadFolders()) ?? []
    }

    private static func makeRunStoreURL() throws -> URL {
        let support = try AppDirectories.applicationSupport()
        let dir = support.appendingPathComponent("Memento", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("runs.json")
    }

    private func saveRuns() {
        guard let data = try? JSONEncoder().encode(runHistory) else { return }
        try? data.write(to: runStoreURL, options: .atomic)
    }

    // MARK: - Rules persistence

    private static func rulesURL() throws -> URL {
        try makeRunStoreURL().deletingLastPathComponent().appendingPathComponent("rules.json")
    }

    private func loadRules() {
        guard let url = try? Self.rulesURL(),
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode(GroupingRules.self, from: data) else { return }
        rules = saved
    }

    private func saveRules() {
        guard let url = try? Self.rulesURL(),
              let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - People persistence

    private static func peopleURL() throws -> URL {
        try makeRunStoreURL().deletingLastPathComponent().appendingPathComponent("people.json")
    }

    private func loadPeople() {
        guard let url = try? Self.peopleURL(),
              let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder().decode([PersonRecord].self, from: data) else { return }
        faceClusters = saved.map(\.cluster)
    }

    /// Only named people are worth remembering; unnamed clusters are re-detected each scan.
    private func savePeople() {
        guard let url = try? Self.peopleURL() else { return }
        let records = faceClusters.filter(\.isNamed).map(PersonRecord.init)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Start run

    func startNewRun(sourceURLs: [URL], destinationURL: URL, placementMode: PlacementMode) {
        let vm = ScanViewModel()
        scanVM = vm
        selectedSection = .scanning
        vm.start(
            sourceURLs: sourceURLs,
            destinationURL: destinationURL,
            placementMode: placementMode,
            rules: rules,
            knownPeople: faceClusters.filter(\.isNamed)
        ) { [weak self] plan in
            Task { @MainActor [weak self] in self?.handlePlanReady(plan) }
        }
    }

    func cancelScan() {
        scanVM?.cancel(); scanVM = nil
        isAwaitingPeopleNames = false
        selectedSection = .newRun
    }

    private func handlePlanReady(_ plan: OrganizationPlan) {
        faceClusters = scanVM?.faceClusters ?? []

        // People mode: name the detected people first, then build the plan from those names.
        if rules.structureMode == .people, !faceClusters.isEmpty {
            isAwaitingPeopleNames = true
            selectedSection = .people
            return
        }
        showPlan(plan)
    }

    private func showPlan(_ plan: OrganizationPlan) {
        isAwaitingPeopleNames = false
        planVM           = PlanViewModel(plan: plan)
        needsReviewItems = plan.needsReviewItems
        duplicateSets    = plan.duplicateSets
        selectedSection  = .plan
    }

    /// Rebuilds the plan using the names assigned on the People screen.
    func continueToPlanWithPeople() async {
        guard let scanVM else { return }
        let people = PeopleAssigner.personByItem(clusters: faceClusters, items: scanVM.organizableItems)
        guard let plan = await scanVM.buildPlan(rules: rules, personByItem: people) else { return }
        showPlan(plan)
    }

    // MARK: - Execute plan

    func applyPlan() {
        guard let planVM else { return }
        let plan = planVM.plan

        // Insert the record immediately so it's always persisted, even if the executor fails.
        var record = RunRecord(id: plan.runID, sourceURLs: plan.sourceURLs, destinationURL: plan.destinationURL)
        // Save the plan beside the journal so the run can be resumed after a relaunch.
        if let planURL = try? Self.planURL(runID: plan.runID),
           let data = try? JSONEncoder().encode(plan) {
            try? data.write(to: planURL, options: .atomic)
            record.planPath = planURL.path
        }
        runHistory.insert(record, at: 0)
        saveRuns()

        Task { await runExecution(plan: plan, resume: false) }
    }

    /// Whether an interrupted run still has the saved plan it needs to be resumed.
    func canResume(_ record: RunRecord) -> Bool {
        guard let path = record.planPath else { return false }
        return FileManager.default.fileExists(atPath: path)
            && FileManager.default.fileExists(atPath: record.journalPath)
    }

    /// Continues an interrupted run: files already copied (per the journal) are skipped,
    /// everything else is transferred as in a normal run.
    func resumeRun(record: RunRecord) async {
        guard let path = record.planPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plan = try? JSONDecoder().decode(OrganizationPlan.self, from: data)
        else {
            revertMessage = "Can't resume: the saved plan for this run is missing."
            return
        }
        if let idx = runHistory.firstIndex(where: { $0.id == record.id }) {
            runHistory[idx].status = .inProgress
            runHistory[idx].interruptionReason = nil
        }
        interruptedRun = nil
        await runExecution(plan: plan, resume: true)
    }

    private static func planURL(runID: UUID) throws -> URL {
        try JournalStore.makeURL(runID: runID).deletingPathExtension().appendingPathExtension("plan.json")
    }

    /// Shared body of a fresh run and a resumed one.
    private func runExecution(plan: OrganizationPlan, resume: Bool) async {
        isExecuting = true
        activeExecutionProgress = nil
        // Keep the Mac awake while files are being moved/copied, even if the
        // screen locks or turns off.
        sleepBlocker.begin(reason: "Organizing photo library")
        defer { sleepBlocker.end() }
        do {
            let journalURL = try JournalStore.makeURL(runID: plan.runID)
            let journal    = try JournalStore(url: journalURL)
            let executor   = Executor()
            let state      = resume ? Executor.ResumeState(entries: try await journal.readAll()) : nil

            if let idx = runHistory.firstIndex(where: { $0.id == plan.runID }) {
                runHistory[idx].journalPath = journalURL.path
            }

            try await executor.execute(plan: plan, journal: journal, resuming: state) { progress in
                Task { @MainActor in
                    self.activeExecutionProgress = progress
                    if let idx = self.runHistory.firstIndex(where: { $0.id == plan.runID }) {
                        self.runHistory[idx].recordCheckpoint(from: progress)
                    }
                }
            }

            if let idx = runHistory.firstIndex(where: { $0.id == plan.runID }) {
                runHistory[idx].status               = .completed
                runHistory[idx].endDate              = Date()
                runHistory[idx].itemsMoved           = activeExecutionProgress?.completed ?? 0
                runHistory[idx].duplicatesQuarantined = activeExecutionProgress?.quarantined ?? 0
            }
            // The journal knows where each file actually landed; index those paths so
            // the library still resolves after a move (and survives relaunch).
            let destBySource = await Self.destinationMap(journal: journal)
            if let store = libraryStore {
                for folder in plan.proposedFolders {
                    let moved = folder.items.compactMap { item -> MediaItem? in
                        guard let dest = destBySource[item.url.path] else { return nil }
                        return item.relocated(to: URL(fileURLWithPath: dest))
                    }
                    try? await store.insertItems(moved, eventName: folder.name, relativePath: folder.relativePath)
                }
            }
            await reloadLibrary()
            await refreshQuarantineCount()
            relocateSamples(using: destBySource)
            savePeople()
        } catch {
            if let idx = runHistory.firstIndex(where: { $0.id == plan.runID }) {
                runHistory[idx].status              = .interrupted
                runHistory[idx].endDate             = Date()
                runHistory[idx].interruptionReason  = error.localizedDescription
                interruptedRun = runHistory[idx]
            }
        }

        saveRuns()
        isExecuting = false
        scanVM = nil
        planVM = nil
        if interruptedRun == nil {
            // These described files in their old locations; after a completed run they're stale.
            duplicateSets = []
            needsReviewItems = []
        }
        selectedSection = interruptedRun == nil ? .history : .interrupted
    }

    // MARK: - Face clusters

    /// Names a cluster. Giving it the same name as another cluster merges the two, which is
    /// how the user fixes one person being split across several clusters.
    func nameCluster(id: UUID, name: String) {
        guard let idx = faceClusters.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        faceClusters[idx].name = trimmed
        defer { savePeople() }

        guard !trimmed.isEmpty,
              let targetIdx = faceClusters.firstIndex(where: {
                  $0.id != id && $0.name?.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
              })
        else { return }

        let source = faceClusters[idx]
        faceClusters[targetIdx].faces += source.faces
        faceClusters[targetIdx].sampleItems = Array((faceClusters[targetIdx].sampleItems + source.sampleItems).prefix(5))
        faceClusters.remove(at: idx)
        faceClusters.sort { $0.totalItemCount > $1.totalItemCount }
    }

    /// Drops a cluster that isn't a real person (or one the user doesn't want a folder for).
    func hideCluster(id: UUID) {
        faceClusters.removeAll { $0.id == id }
        savePeople()
    }

    /// Points people's sample photos at their new locations after a run moved them.
    private func relocateSamples(using destBySource: [String: String]) {
        for c in faceClusters.indices {
            faceClusters[c].sampleItems = faceClusters[c].sampleItems.map { item in
                destBySource[item.url.path].map { item.relocated(to: URL(fileURLWithPath: $0)) } ?? item
            }
        }
    }

    /// source path → destination path for every completed copy in a run's journal.
    private static func destinationMap(journal: JournalStore) async -> [String: String] {
        let entries = (try? await journal.readAll()) ?? []
        var map: [String: String] = [:]
        for e in entries where e.op == .copy && e.status == .completed {
            if let dest = e.destPath { map[e.sourcePath] = dest }
        }
        return map
    }

    // MARK: - Revert

    /// Outcome of the last revert, shown to the user. Nil until a revert has run.
    var revertMessage: String?

    func revertRun(record: RunRecord) async {
        let journalURL = URL(fileURLWithPath: record.journalPath)
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            revertMessage = "Can't revert: the journal for this run is missing."
            return
        }
        do {
            let store  = try JournalStore(url: journalURL)
            let destPaths = Array(await Self.destinationMap(journal: store).values)
            let result = try await store.revert()
            try? await libraryStore?.deleteItems(atPaths: destPaths)
            await reloadLibrary()
            await refreshQuarantineCount()
            if let idx = runHistory.firstIndex(where: { $0.id == record.id }) {
                // Only call it reverted when every file came back; otherwise the run is
                // partially undone and the user needs to know.
                runHistory[idx].status  = result.failed == 0 ? .reverted : .interrupted
                runHistory[idx].endDate = Date()
                if result.failed > 0 {
                    runHistory[idx].interruptionReason = "Revert incomplete: \(result.failed) file(s) could not be restored."
                }
            }
            saveRuns()
            revertMessage = result.failed == 0
                ? "Reverted \(result.reverted) file(s)."
                : "Reverted \(result.reverted) file(s); \(result.failed) could not be restored. Check the journal CSV for details."
        } catch {
            revertMessage = "Revert failed: \(error.localizedDescription)"
        }
    }

    func revertToCheckpoint(token: String, in record: RunRecord) async {
        let journalURL = URL(fileURLWithPath: record.journalPath)
        guard FileManager.default.fileExists(atPath: journalURL.path) else {
            revertMessage = "Can't revert: the journal for this run is missing."
            return
        }
        do {
            let store  = try JournalStore(url: journalURL)
            let result = try await store.revert(afterCheckpointToken: token)
            revertMessage = result.failed == 0
                ? "Reverted \(result.reverted) file(s) back to checkpoint."
                : "Reverted \(result.reverted) file(s); \(result.failed) could not be restored."
        } catch {
            revertMessage = "Revert failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Dismiss interrupted run

    func dismissInterruptedRun() {
        interruptedRun = nil
        if selectedSection == .interrupted { selectedSection = .timeline }
    }

    // MARK: - Export

    func journalCSV(for record: RunRecord) async -> String {
        let url = URL(fileURLWithPath: record.journalPath)
        guard let store = try? JournalStore(url: url) else { return "" }
        let entries = (try? await store.readAll()) ?? []
        var lines = ["runID,checkpointID,sourcePath,destPath,sha256,bytes,timestamp,op,status"]
        for e in entries {
            let fields = [
                e.runID, e.checkpointID ?? "",
                e.sourcePath, e.destPath ?? "",
                e.sha256 ?? "",
                String(e.bytes), String(e.timestamp),
                e.op.rawValue, e.status.rawValue
            ]
            lines.append(fields
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: ",")
            )
        }
        return lines.joined(separator: "\n")
    }
}
