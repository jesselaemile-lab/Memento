import Foundation
import CoreLocation

@Observable
@MainActor
final class PlacesViewModel {

    struct LocationCluster: Identifiable {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
        let name: String
        let count: Int
    }

    /// Clusters, pre-sorted by descending count so the list pane never re-sorts on render.
    private(set) var clusters: [LocationCluster] = []
    private(set) var noLocationCount: Int = 0

    // Recompute only when the folder set actually changes, not on every map pan / selection.
    private var builtForCount: Int = -1

    func rebuildIfNeeded(from folders: [PlannedFolder]) {
        guard folders.count != builtForCount else { return }
        builtForCount = folders.count
        rebuild(from: folders)
    }

    private func rebuild(from folders: [PlannedFolder]) {
        var result: [LocationCluster] = []
        var noLoc = 0

        for folder in folders {
            var latSum = 0.0, lonSum = 0.0, located = 0
            for item in folder.items {
                if let loc = item.location {
                    latSum += loc.latitude; lonSum += loc.longitude; located += 1
                } else {
                    noLoc += 1
                }
            }
            guard located > 0 else { continue }
            result.append(LocationCluster(
                id: folder.id,
                coordinate: CLLocationCoordinate2D(
                    latitude: latSum / Double(located),
                    longitude: lonSum / Double(located)
                ),
                name: folder.name,
                count: located
            ))
        }

        noLocationCount = noLoc
        clusters = result.sorted { $0.count > $1.count }
    }
}
