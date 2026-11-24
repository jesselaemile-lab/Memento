import Foundation

nonisolated struct PlanBuilder {
    let rules: GroupingRules

    func build(
        events: [MediaEvent],
        allItems: [MediaItem],
        destinationURL: URL,
        placementMode: PlacementMode,
        sourceURLs: [URL],
        personByItem: [UUID: String] = [:]
    ) -> OrganizationPlan {
        var plan = OrganizationPlan(
            destinationURL: destinationURL,
            placementMode: placementMode,
            sourceURLs: sourceURLs
        )


        // Separate screenshots if the user hasn't opted them in
        var screenshotItems: [MediaItem] = []
        var regularItems = allItems
        if !rules.includeScreenshots {
            screenshotItems = allItems.filter { $0.isScreenshot }
            regularItems    = allItems.filter { !$0.isScreenshot }
        }
        plan.screenshotItems = screenshotItems

        // Undated items can't be placed by date — they wait in Needs review until the user
        // assigns a date or folder, so keep them out of the proposed folders.
        let events: [MediaEvent] = events.compactMap { event in
            let dated = event.items.filter { $0.captureDate != nil }
            guard !dated.isEmpty else { return nil }
            var e = event; e.items = dated; return e
        }

        // Year › Month and People place each item individually rather than per event:
        // "2023/04-April" or "Jesse/2026/Christmas".
        switch rules.structureMode {
        case .yearMonth:
            plan.proposedFolders = bucketFolders(from: events) { item, event in
                monthPath(for: item.captureDate ?? event.startDate)
            }
            plan.needsReviewItems = regularItems.filter { $0.captureDate == nil }
            return plan
        case .people:
            plan.proposedFolders = bucketFolders(from: events) { item, event in
                // A name like "Mom/Dad" must not create an extra folder level.
                let person = personByItem[item.id]
                    .map { $0.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
                    ?? PlanBuilder.noPersonFolder
                return person + "/" + peopleSubPath(for: item, in: event)
            }
            plan.needsReviewItems = regularItems.filter { $0.captureDate == nil }
            return plan
        default:
            break
        }

        // Build folders from events. Events that resolve to the same path (e.g. you went
        // Sunrise → Mount Dora → back to Sunrise) share one folder instead of "Sunrise (2)".
        var indexByPath: [String: Int] = [:]
        for event in events {
            let path = buildRelativePath(for: event)
            if let idx = indexByPath[path] {
                var merged = plan.proposedFolders[idx]
                merged.items += event.items
                if var e = merged.event {
                    e.items = merged.items
                    e.startDate = min(e.startDate, event.startDate)
                    e.endDate = max(e.endDate, event.endDate)
                    e.evidenceTags = Array(Set(e.evidenceTags + event.evidenceTags)).sorted { $0.rawValue < $1.rawValue }
                    merged.event = e
                }
                merged.conflicts = detectConflicts(in: merged.items)
                plan.proposedFolders[idx] = merged
                continue
            }
            var folder = PlannedFolder(
                name: event.name,
                relativePath: path,
                items: event.items,
                event: event
            )
            folder.conflicts = detectConflicts(in: event.items)
            indexByPath[path] = plan.proposedFolders.count
            plan.proposedFolders.append(folder)
        }

        // Items with no date → needsReview
        plan.needsReviewItems = regularItems.filter { $0.captureDate == nil }

        return plan
    }

    // MARK: - Path construction

    /// Formats a month folder name like "04-April".
    private static let monthFolderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-MMMM"
        return f
    }()

    /// Folder for photos where no named person is the main subject.
    static let noPersonFolder = "_Other photos"

    /// "2026/12-December"
    static func monthPath(for date: Date) -> String {
        let year = Calendar.current.component(.year, from: date)
        return "\(year)/\(monthFolderFormatter.string(from: date))"
    }

    private func monthPath(for date: Date) -> String { PlanBuilder.monthPath(for: date) }

    /// Path inside a person's folder, per the chosen People sub-structure.
    private func peopleSubPath(for item: MediaItem, in event: MediaEvent) -> String {
        switch rules.peopleSubStructure {
        case .yearMonth:
            return monthPath(for: item.captureDate ?? event.startDate)
        case .yearEvent:
            return buildRelativePath(for: event, mode: .yearEvent)
        case .place:
            return event.locationName ?? "Unknown place"
        }
    }

    /// Groups every item of every event into a folder keyed by `pathFor`, sorted by path.
    /// Each folder gets a synthetic event so downstream views work.
    private func bucketFolders(
        from events: [MediaEvent],
        pathFor: (MediaItem, MediaEvent) -> String
    ) -> [PlannedFolder] {
        var order: [String] = []
        var buckets: [String: [MediaItem]] = [:]

        for event in events {
            for item in event.items {
                let path = pathFor(item, event)
                if buckets[path] == nil { order.append(path) }
                buckets[path, default: []].append(item)
            }
        }

        return order.compactMap { path in
            guard let items = buckets[path] else { return nil }
            let name = (path as NSString).lastPathComponent
            var folder = PlannedFolder(
                name: name,
                relativePath: path,
                items: items,
                event: MediaEvent(name: name, items: items)
            )
            folder.conflicts = detectConflicts(in: items)
            return folder
        }
        .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
    }

    private func buildRelativePath(for event: MediaEvent, mode: GroupingRules.StructureMode? = nil) -> String {
        let cal   = Calendar.current
        let year  = cal.component(.year,  from: event.startDate)
        let month = cal.component(.month, from: event.startDate)
        let day   = cal.component(.day,   from: event.startDate)
        let mm    = String(format: "%02d", month)
        let dd    = String(format: "%02d", day)

        switch mode ?? rules.structureMode {
        case .yearEvent:
            // An event named only after the old album folder ("Sep25-Mar26") goes straight
            // into the month folder unless the user opted to keep album names.
            if event.evidenceTags.contains(.sourceFolderName), !rules.reuseSourceFolderNames {
                return PlanBuilder.monthPath(for: event.startDate)
            }
            // Too few photos to be an event (stragglers) — keep them loose in the month.
            if event.items.count < rules.minimumItemsPerGroup, !event.evidenceTags.contains(.holiday) {
                return PlanBuilder.monthPath(for: event.startDate)
            }
            // "2023/10-October/Roosevelt" — events nest under their month like Year › Month.
            let leaf = applyTemplate(rules.namingTemplate, year: year, mm: mm, dd: dd, event: event)
            return "\(PlanBuilder.monthPath(for: event.startDate))/\(leaf)"
        case .yearMonth:
            let monthName = PlanBuilder.monthFolderFormatter.string(from: event.startDate)
            return "\(year)/\(monthName)"
        case .eventOnly:
            return applyTemplate(rules.namingTemplate, year: year, mm: mm, dd: dd, event: event)
        case .people:
            return event.name
        case .place:
            return event.locationName ?? event.name
        }
    }

    private func applyTemplate(_ template: String, year: Int, mm: String, dd: String, event: MediaEvent) -> String {
        let result = template
            .replacingOccurrences(of: "{yyyy}",   with: "\(year)")
            .replacingOccurrences(of: "{mm}",     with: mm)
            .replacingOccurrences(of: "{dd}",     with: dd)
            .replacingOccurrences(of: "{event}",  with: event.name)
            .replacingOccurrences(of: "{place}",  with: event.locationName ?? "")
            .replacingOccurrences(of: "{person}", with: "")
            .replacingOccurrences(of: "{camera}", with: "")
        // Collapse any double spaces left by empty tokens and trim
        return result
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Conflict detection (Safety rule 6: never overwrite)

    private func detectConflicts(in items: [MediaItem]) -> [FilenameConflict] {
        var seen: [String: MediaItem] = [:]
        var counters: [String: Int]  = [:]
        var conflicts: [FilenameConflict] = []

        for item in items {
            let name = item.filename
            if let existing = seen[name] {
                let sameContent = existing.sha256 != nil && existing.sha256 == item.sha256
                let n = (counters[name] ?? 1) + 1
                counters[name] = n
                let ext  = (name as NSString).pathExtension
                let base = (name as NSString).deletingPathExtension
                let resolved = sameContent ? name : "\(base) (\(n)).\(ext)"
                conflicts.append(FilenameConflict(
                    originalName: name,
                    resolvedName: resolved,
                    reason: sameContent ? .identical : .differentContent
                ))
            } else {
                seen[name] = item
            }
        }
        return conflicts
    }
}
