import Foundation

@Observable
@MainActor
final class FoldersViewModel {

    enum SortField { case name, items, size, date }

    private(set) var sortField: SortField = .date
    private(set) var sortAscending: Bool = false

    /// Pre-sorted folders and totals, recomputed only when the folder set or sort changes.
    private(set) var sortedFolders: [PlannedFolder] = []
    private(set) var totalItemCount: Int = 0
    private(set) var totalSize: Int64 = 0

    private var builtForCount: Int = -1

    func rebuildIfNeeded(from folders: [PlannedFolder]) {
        guard folders.count != builtForCount else { return }
        builtForCount = folders.count
        totalItemCount = folders.reduce(0) { $0 + $1.itemCount }
        totalSize = folders.reduce(0) { $0 + $1.totalSize }
        applySort(folders)
    }

    func toggleSort(_ field: SortField, folders: [PlannedFolder]) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = false
        }
        applySort(folders)
    }

    private func applySort(_ folders: [PlannedFolder]) {
        sortedFolders = folders.sorted {
            switch sortField {
            case .name:  return sortAscending ? $0.name < $1.name : $0.name > $1.name
            case .items: return sortAscending ? $0.itemCount < $1.itemCount : $0.itemCount > $1.itemCount
            case .size:  return sortAscending ? $0.totalSize < $1.totalSize : $0.totalSize > $1.totalSize
            case .date:
                let a = $0.event?.startDate ?? .distantPast
                let b = $1.event?.startDate ?? .distantPast
                return sortAscending ? a < b : a > b
            }
        }
    }
}
