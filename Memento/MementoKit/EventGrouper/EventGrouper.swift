import Foundation
import CoreLocation

nonisolated struct EventGrouper {
    let rules: GroupingRules

    // One formatter shared across all events; DateFormatter() construction is expensive.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM d"
        return f
    }()

    func group(items: [MediaItem]) -> [MediaEvent] {
        guard !items.isEmpty else { return [] }

        let sorted = items.sorted { $0.effectiveCaptureDate < $1.effectiveCaptureDate }
        var rawGroups: [[MediaItem]] = [[sorted[0]]]

        for item in sorted.dropFirst() {
            if shouldSplit(prev: rawGroups.last!.last!, next: item) {
                rawGroups.append([item])
            } else {
                rawGroups[rawGroups.count - 1].append(item)
            }
        }

        rawGroups = mergeSmallGroups(rawGroups)
        return rawGroups.enumerated().map { makeEvent(from: $1, index: $0) }
    }

    // MARK: - Split decisions

    private func shouldSplit(prev: MediaItem, next: MediaItem) -> Bool {
        if let p = prev.captureDate, let n = next.captureDate {
            if n.timeIntervalSince(p) / 3600 > rules.timeGapHours { return true }
            // Events never cross a month boundary, so every photo files under its own month.
            if !Calendar.current.isDate(p, equalTo: n, toGranularity: .month) { return true }
        }
        if let pLoc = prev.location, let nLoc = next.location {
            // Haversine avoids allocating CLLocation ObjC objects for every item pair.
            if haversineKm(pLoc, nLoc) > rules.locationGapKilometers { return true }
        }
        return false
    }

    private func isNearby(_ a: [MediaItem], _ b: [MediaItem]) -> Bool {
        guard let end = a.compactMap(\.captureDate).max(),
              let start = b.compactMap(\.captureDate).min() else { return true }
        let hours = abs(start.timeIntervalSince(end)) / 3600
        return hours <= rules.timeGapHours * 3
            && Calendar.current.isDate(end, equalTo: start, toGranularity: .month)
    }

    private func haversineKm(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let R = 6371.0
        let dLat = (b.latitude  - a.latitude)  * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let s = sin(dLat / 2), t = sin(dLon / 2)
        let h = s * s + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * t * t
        return R * 2 * asin(min(1, sqrt(h)))
    }

    private func mergeSmallGroups(_ groups: [[MediaItem]]) -> [[MediaItem]] {
        guard groups.count > 1 else { return groups }
        var result: [[MediaItem]] = []
        for group in groups {
            // Only absorb a small group into a *nearby* neighbour (same month, gap no more
            // than 3× the time-gap rule). Distant stragglers stay on their own instead of
            // stretching an event across months.
            if group.count < rules.minimumItemsPerGroup, let prev = result.last,
               isNearby(prev, group) {
                result[result.count - 1].append(contentsOf: group)
            } else {
                result.append(group)
            }
        }
        // A leading small group has no previous neighbour — merge it forward if nearby.
        if result.count >= 2, result[0].count < rules.minimumItemsPerGroup, isNearby(result[0], result[1]) {
            result[1].insert(contentsOf: result[0], at: 0)
            result.removeFirst()
        }
        // A lone group under threshold still gets its own folder.
        return result
    }

    // MARK: - Event construction

    private func makeEvent(from items: [MediaItem], index: Int) -> MediaEvent {
        var event = MediaEvent(name: deriveName(from: items, index: index), items: items)

        // Evidence tags
        if hasTimeGapEvidence(items)   { event.evidenceTags.append(.timeGap) }
        if hasGPSEvidence(items)       { event.evidenceTags.append(.gpsRadius) }
        if hasHolidayEvidence(items)   { event.evidenceTags.append(.holiday) }

        // Remember when the name is just the old album folder, so PlanBuilder can file
        // the photos at month level instead of keeping that album as a subfolder.
        if let folder = dominantSourceFolder(items), !isTrivialFolderName(folder) {
            event.sourceDescription = folder
            if event.name == folder { event.evidenceTags.append(.sourceFolderName) }
        }

        return event
    }

    private func deriveName(from items: [MediaItem], index: Int) -> String {
        let dates = items.compactMap(\.captureDate).sorted()
        guard let first = dates.first else {
            return "Event \(index + 1)"
        }
        // Return just the descriptive label — PlanBuilder applies year/month via the naming template.
        if let folder = dominantSourceFolder(items),
           !isTrivialFolderName(folder) {
            return folder
        }

        let last = dates.last ?? first
        let cal = Calendar.current

        // A short event overlapping a holiday is named after it ("Christmas").
        // Long trips that merely contain a holiday keep their date-range name.
        if rules.recognizeHolidays,
           last.timeIntervalSince(first) <= 4 * 86_400,
           let holiday = HolidayCalendar.holidayName(overlapping: first, last, calendar: cal) {
            return holiday
        }

        // Date-range label so events in the same month stay distinguishable:
        // "March 14", "March 14–16", or "March 28 – April 2".
        if cal.isDate(first, inSameDayAs: last) {
            return EventGrouper.dayFormatter.string(from: first)
        }
        if cal.component(.month, from: first) == cal.component(.month, from: last),
           cal.component(.year, from: first) == cal.component(.year, from: last) {
            return "\(EventGrouper.dayFormatter.string(from: first))–\(cal.component(.day, from: last))"
        }
        return "\(EventGrouper.dayFormatter.string(from: first)) – \(EventGrouper.dayFormatter.string(from: last))"
    }

    private func dominantSourceFolder(_ items: [MediaItem]) -> String? {
        let folders = items.map { $0.url.deletingLastPathComponent().lastPathComponent }
        let freq = Dictionary(folders.map { ($0, 1) }, uniquingKeysWith: +)
        return freq.max(by: { $0.value < $1.value })?.key
    }

    private func isTrivialFolderName(_ name: String) -> Bool {
        let trivial = ["dcim", "img", "dsc", "dji", "100apple", "misc", "new folder",
                       "camera", "downloads", "desktop", "pictures", "photos", "videos"]
        let lower = name.lowercased()
        if trivial.contains(lower) { return true }
        // DCIM camera subfolder: starts with 3 digits then a letter, e.g. "100CANON", "100CANON-March to May2026"
        if lower.count >= 4,
           lower.prefix(3).allSatisfy({ $0.isNumber }),
           lower.dropFirst(3).first?.isLetter == true { return true }
        // Mostly digits → date-derived or sequence folder
        let digits = lower.filter { $0.isNumber }
        return Double(digits.count) / Double(max(1, lower.count)) > 0.6
    }

    private func hasTimeGapEvidence(_ items: [MediaItem]) -> Bool {
        let dates = items.compactMap(\.captureDate).sorted()
        guard let first = dates.first, let last = dates.last else { return false }
        return last.timeIntervalSince(first) / 3600 > rules.timeGapHours
    }

    private func hasGPSEvidence(_ items: [MediaItem]) -> Bool {
        items.contains { $0.location != nil }
    }

    private func hasHolidayEvidence(_ items: [MediaItem]) -> Bool {
        guard rules.recognizeHolidays else { return false }
        let dates = items.compactMap(\.captureDate).sorted()
        guard let first = dates.first, let last = dates.last,
              last.timeIntervalSince(first) <= 4 * 86_400 else { return false }
        return HolidayCalendar.holidayName(overlapping: first, last) != nil
    }
}
