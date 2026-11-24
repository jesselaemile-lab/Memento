import Foundation

@Observable
@MainActor
final class PlanViewModel {
    var plan: OrganizationPlan
    var selectedFolderID: UUID?
    var selectedFolder: PlannedFolder? { plan.proposedFolders.first { $0.id == selectedFolderID } }
    var expandedYears: Set<Int>

    init(plan: OrganizationPlan) {
        self.plan = plan
        // Expand all years by default
        let years = Set(plan.proposedFolders.compactMap { $0.event?.year })
        self.expandedYears = years
    }

    // MARK: - Computed

    var foldersByYear: [(year: Int, folders: [PlannedFolder])] {
        let dict = Dictionary(grouping: plan.proposedFolders) { folder in
            folder.event?.year ?? 0
        }
        return dict.keys.sorted(by: >).map { year in
            (year: year, folders: dict[year]!.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            })
        }
    }

    /// "2023/10-October/Roosevelt" → "Roosevelt"; "2023/10-October" → "10-October"
    nonisolated static func leafName(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// "2023/10-October/Roosevelt" → "10-October"; nil when the folder *is* the month.
    nonisolated static func monthComponent(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 3, Int(parts[0]) != nil else { return nil }
        return String(parts[1])
    }

    /// "2023/10-October/Roosevelt" → "10-October/Roosevelt"
    nonisolated static func pathBelowYear(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1, parts[0].count == 4, Int(parts[0]) != nil else { return path }
        return parts.dropFirst().joined(separator: "/")
    }

    /// Estimate for applying the plan. A move within one volume is a rename per file;
    /// anything else streams every byte (write + two verification reads), so it scales
    /// with total size over the throughput measured during the scan.
    var estimatedDuration: String {
        let items = plan.totalItems + plan.duplicateSets.flatMap(\.quarantined).count
        let seconds: Double
        if plan.placementMode == .move, VolumeCheck.sameVolume(plan.sourceURLs.first, plan.destinationURL) {
            seconds = Double(items) * 0.01
        } else if plan.placementMode == .hardlink {
            seconds = Double(items) * 0.005
        } else {
            // Fall back to a conservative SSD figure if the scan didn't measure anything.
            let bytesPerSecond = plan.measuredBytesPerSecond ?? 400_000_000
            seconds = Double(plan.totalSize) * 3 / bytesPerSecond + Double(items) * 0.01
        }
        return PlanViewModel.formatEstimate(seconds)
    }

    nonisolated static func formatEstimate(_ seconds: Double) -> String {
        if seconds < 5   { return "a few seconds" }
        if seconds < 60  { return "about \(Int((seconds / 5).rounded(.up)) * 5) sec" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60  { return "about \(minutes) min" }
        return "about \(minutes / 60) hr \(minutes % 60) min"
    }

    // MARK: - Folder modifications

    func rename(folder: PlannedFolder, to newName: String) {
        guard let idx = plan.proposedFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        plan.proposedFolders[idx].name = newName
        let oldPath = plan.proposedFolders[idx].relativePath
        let dir = (oldPath as NSString).deletingLastPathComponent
        plan.proposedFolders[idx].relativePath = (dir as NSString).appendingPathComponent(newName)
    }

    func merge(folder: PlannedFolder, into target: PlannedFolder) {
        guard let srcIdx = plan.proposedFolders.firstIndex(where: { $0.id == folder.id }),
              let dstIdx = plan.proposedFolders.firstIndex(where: { $0.id == target.id })
        else { return }
        plan.proposedFolders[dstIdx].items.append(contentsOf: plan.proposedFolders[srcIdx].items)
        plan.proposedFolders.remove(at: srcIdx)
    }

    func exclude(folder: PlannedFolder) {
        plan.proposedFolders.removeAll { $0.id == folder.id }
    }

    /// Resolves Needs-review items: stamps them with `date`, moves them out of whatever
    /// folder they were in, and files them under `folderName` (or the month folder for
    /// `date` when blank). Removes them from the review list.
    func resolveReviewItems(_ items: [MediaItem], date: Date, folderName: String) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
        let year = Calendar.current.component(.year, from: date)
        let path = trimmed.isEmpty ? PlanBuilder.monthPath(for: date) : "\(year)/\(trimmed)"

        let resolved: [MediaItem] = items.map { item in
            var i = item
            i.captureDate = date
            i.dateSource = .userProvided
            i.hasMissingEXIF = false
            return i
        }

        // Ambiguous items were already placed by a guessed date — pull them out first.
        for f in plan.proposedFolders.indices {
            plan.proposedFolders[f].items.removeAll { ids.contains($0.id) }
        }
        plan.proposedFolders.removeAll { $0.items.isEmpty }

        if let idx = plan.proposedFolders.firstIndex(where: { $0.relativePath == path }) {
            plan.proposedFolders[idx].items.append(contentsOf: resolved)
        } else {
            let name = (path as NSString).lastPathComponent
            plan.proposedFolders.append(PlannedFolder(
                name: name, relativePath: path, items: resolved,
                event: MediaEvent(name: name, items: resolved)
            ))
            plan.proposedFolders.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        }
        plan.needsReviewItems.removeAll { ids.contains($0.id) }
        expandedYears.insert(year)
    }

    enum KeeperRule: String, CaseIterable, Hashable {
        case highestRes  = "Highest resolution"
        case largestFile = "Largest file"
        case oldestDate  = "Oldest"
    }

    /// The bulk rule last applied; nil until the Duplicates screen first opens, so manual
    /// picks aren't overwritten when the user navigates back.
    private(set) var appliedKeeperRule: KeeperRule?

    /// Picks the keeper in every set that quarantines copies, using `rule`.
    func applyKeeperRule(_ rule: KeeperRule) {
        appliedKeeperRule = rule
        for set in plan.duplicateSets where set.kind.quarantinesCopies {
            let pick: MediaItem?
            switch rule {
            case .highestRes:
                pick = set.items.max {
                    let a = $0.dimensions.map { $0.width * $0.height } ?? 0
                    let b = $1.dimensions.map { $0.width * $0.height } ?? 0
                    return a == b ? $0.fileSize < $1.fileSize : a < b
                }
            case .largestFile:
                pick = set.items.max { $0.fileSize < $1.fileSize }
            case .oldestDate:
                pick = set.items.min { ($0.captureDate ?? .distantFuture) < ($1.captureDate ?? .distantFuture) }
            }
            if let pick { setKeeperRule(for: set, keeperID: pick.id) }
        }
    }

    /// Changes which copy of a duplicate set is kept. The plan's folders were built with the
    /// old keeper in place, so the new keeper takes its slot and the old one becomes a
    /// quarantine candidate — otherwise the old file would be moved twice and the new one never.
    func setKeeperRule(for set: DuplicateSet, keeperID: UUID) {
        guard let idx = plan.duplicateSets.firstIndex(where: { $0.id == set.id }),
              let newKeeper = plan.duplicateSets[idx].items.first(where: { $0.id == keeperID })
        else { return }
        let oldKeeperID = plan.duplicateSets[idx].keeperID
        guard oldKeeperID != keeperID else { return }
        plan.duplicateSets[idx].keeperID = keeperID

        // Only kinds that quarantine copies left the non-keepers out of the folders.
        guard plan.duplicateSets[idx].kind.quarantinesCopies else { return }
        for f in plan.proposedFolders.indices {
            if let i = plan.proposedFolders[f].items.firstIndex(where: { $0.id == oldKeeperID }) {
                plan.proposedFolders[f].items[i] = newKeeper
                return
            }
        }
    }
}
