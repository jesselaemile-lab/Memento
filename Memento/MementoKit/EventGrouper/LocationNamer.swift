import Foundation
import CoreLocation
import MapKit

/// Resolves human-readable place names for events by reverse-geocoding a
/// representative photo coordinate. Results are cached on a ~1 km grid so
/// events at the same place don't trigger duplicate network lookups.
final class LocationNamer {
    private var cache: [String: String?] = [:]

    /// Fills `locationName` for events whose photos carry GPS data and appends
    /// the place to the event name, e.g. "March 14–16 · San Francisco".
    /// Geocoding failures (offline, rate limit) leave the event unchanged.
    func nameEvents(_ events: [MediaEvent]) async -> [MediaEvent] {
        var named = events
        for i in named.indices {
            guard named[i].locationName == nil,
                  let coord = Self.representativeCoordinate(of: named[i].items),
                  let place = await locationName(for: coord) else { continue }
            named[i].locationName = place
            if !named[i].name.localizedCaseInsensitiveContains(place) {
                named[i].name += " · \(place)"
            }
        }
        return named
    }

    func locationName(for coord: CLLocationCoordinate2D) async -> String? {
        let key = String(format: "%.2f,%.2f", coord.latitude, coord.longitude)
        if let hit = cache[key] { return hit }
        let location = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        var name: String? = nil
        if let request = MKReverseGeocodingRequest(location: location),
           let address = (try? await request.mapItems)?.first?.addressRepresentations {
            name = address.cityName ?? address.regionName
        }
        cache[key] = name
        return name
    }

    /// Median coordinate of the items that have GPS — robust against a single
    /// stray photo taken far from the rest of the event.
    static func representativeCoordinate(of items: [MediaItem]) -> CLLocationCoordinate2D? {
        let coords = items.compactMap(\.location)
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude).sorted()
        let lons = coords.map(\.longitude).sorted()
        return CLLocationCoordinate2D(latitude: lats[lats.count / 2], longitude: lons[lons.count / 2])
    }
}
