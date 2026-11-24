import Foundation

// MARK: - MonthGroup

struct MonthGroup: Identifiable, Sendable {
    let id: String  // "yyyy-mm" key
    let year: Int
    let month: Int
    let count: Int
    var isExpanded: Bool = false
    var loadedItems: [LibraryRow] = []
    var offset: Int = 0
    var hasMore: Bool { loadedItems.count < count }

    var title: String {
        var comps = DateComponents(); comps.year = year; comps.month = month
        let date = Calendar.current.date(from: comps) ?? Date()
        let fmt = DateFormatter(); fmt.dateFormat = "MMMM yyyy"
        return fmt.string(from: date)
    }
}

// MARK: - TimelineViewModel

@Observable
@MainActor
final class TimelineViewModel {

    var monthGroups: [MonthGroup] = []
    var totalCount: Int = 0
    var isLoading: Bool = false

    private let pageSize = 60
    private var store: LibraryStore?

    func setup(store: LibraryStore) async {
        self.store = store
        isLoading = true
        do {
            let raw = try await store.monthGroups()
            totalCount = try await store.totalCount()
            monthGroups = raw.map { row in
                MonthGroup(id: "\(row.year)-\(String(format: "%02d", row.month))",
                           year: row.year, month: row.month, count: row.count)
            }
            // Auto-expand the most recent month
            if !monthGroups.isEmpty {
                await toggleMonth(id: monthGroups[0].id)
            }
        } catch {}
        isLoading = false
    }

    func toggleMonth(id: String) async {
        guard let idx = monthGroups.firstIndex(where: { $0.id == id }) else { return }
        if monthGroups[idx].isExpanded {
            monthGroups[idx].isExpanded = false
        } else {
            monthGroups[idx].isExpanded = true
            if monthGroups[idx].loadedItems.isEmpty {
                await loadPage(idx: idx)
            }
        }
    }

    func loadMoreIfNeeded(for id: String) async {
        guard let idx = monthGroups.firstIndex(where: { $0.id == id }),
              monthGroups[idx].hasMore,
              monthGroups[idx].isExpanded
        else { return }
        await loadPage(idx: idx)
    }

    private func loadPage(idx: Int) async {
        guard let store else { return }
        let group = monthGroups[idx]
        do {
            let page = try await store.items(
                year: group.year, month: group.month,
                offset: group.offset, limit: pageSize
            )
            monthGroups[idx].loadedItems.append(contentsOf: page)
            monthGroups[idx].offset += page.count
        } catch {}
    }
}
