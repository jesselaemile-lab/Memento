import Foundation

// MARK: - Supporting types

struct ItemPair: Sendable {
    let primary: MediaItem    // RAW or HEIC
    let companion: MediaItem  // JPEG or MOV
    let kind: DuplicateKind
}

// MARK: - DuplicateClassifier

/// Classifies a flat list of MediaItems into all six duplicate kinds.
/// Safe to call from any context — pure value computation.
nonisolated struct DuplicateClassifier {
    var burstTimeWindow: TimeInterval = 2.0
    var perceptualHashMaxDistance: Int = 10

    struct Result: Sendable {
        var byteIdenticalSets: [DuplicateSet]     = []
        var lowerResolutionSets: [DuplicateSet]   = []
        var rawJpegPairs: [ItemPair]              = []
        var livePhotoPairs: [ItemPair]            = []
        var burstGroups: [DuplicateSet]           = []
        var screenshotIDs: Set<UUID>              = []

        var allDuplicateSets: [DuplicateSet] {
            byteIdenticalSets + lowerResolutionSets + burstGroups
        }
    }

    func classify(items: [MediaItem]) -> Result {
        var result = Result()

        // These two are NOT duplicates — just pairings to keep together.
        result.rawJpegPairs   = findRawJpegPairs(in: items)
        result.livePhotoPairs = findLivePhotoPairs(in: items)

        // Build set of IDs that are part of a valid pairing (not to quarantine).
        let pairedIDs: Set<UUID> = Set(
            (result.rawJpegPairs + result.livePhotoPairs)
                .flatMap { [$0.primary.id, $0.companion.id] }
        )

        // Exclude paired items from further duplicate analysis.
        let candidates = items.filter { !pairedIDs.contains($0.id) }

        // Pass 1: Byte-identical (same SHA-256)
        result.byteIdenticalSets = findByteIdentical(in: candidates)
        let classifiedIDs = Set(result.byteIdenticalSets.flatMap { $0.items.map(\.id) })
        let remaining = candidates.filter { !classifiedIDs.contains($0.id) }

        // Pass 2: Same photo, lower resolution (pHash match + different dimensions)
        result.lowerResolutionSets = findLowerResolution(in: remaining)
        let lrIDs = Set(result.lowerResolutionSets.flatMap { $0.items.map(\.id) })
        let remaining2 = remaining.filter { !lrIDs.contains($0.id) }

        // Pass 3: Near-identical burst (pHash match + timestamps within 2 s)
        result.burstGroups = findBursts(in: remaining2)

        // Pass 4: Screenshots → flag for routing to _Screenshots folder
        result.screenshotIDs = Set(items.filter { $0.isScreenshot }.map(\.id))

        return result
    }

    // MARK: - RAW + JPEG pair

    private func findRawJpegPairs(in items: [MediaItem]) -> [ItemPair] {
        let byBasename = Dictionary(grouping: items) { $0.url.deletingPathExtension().lastPathComponent }
        var pairs: [ItemPair] = []
        for (_, group) in byBasename where group.count >= 2 {
            guard let raw  = group.first(where: { MediaItem.rawExtensions.contains($0.fileExtension) }),
                  let jpeg = group.first(where: { MediaItem.photoExtensions.contains($0.fileExtension) })
            else { continue }
            pairs.append(ItemPair(primary: raw, companion: jpeg, kind: .rawJpegPair))
        }
        return pairs
    }

    // MARK: - Live Photo pair (.HEIC + .MOV, same basename)

    private func findLivePhotoPairs(in items: [MediaItem]) -> [ItemPair] {
        let byBasename = Dictionary(grouping: items) { $0.url.deletingPathExtension().lastPathComponent }
        var pairs: [ItemPair] = []
        for (_, group) in byBasename where group.count >= 2 {
            guard let heic = group.first(where: { ["heic","heif"].contains($0.fileExtension) }),
                  let mov  = group.first(where: { $0.fileExtension == "mov" })
            else { continue }
            pairs.append(ItemPair(primary: heic, companion: mov, kind: .livePhotoComponents))
        }
        return pairs
    }

    // MARK: - Byte-identical (same SHA-256)

    private func findByteIdentical(in items: [MediaItem]) -> [DuplicateSet] {
        let withHash = items.filter { $0.sha256 != nil }
        let byHash   = Dictionary(grouping: withHash) { $0.sha256! }
        return byHash.values
            .filter { $0.count > 1 }
            .map { group -> DuplicateSet in
                var set = DuplicateSet(kind: .byteIdentical, items: group)
                // Keep copy at the oldest path (earliest capture date).
                if let oldest = group.min(by: {
                    ($0.captureDate ?? .distantFuture) < ($1.captureDate ?? .distantFuture)
                }) { set.keeperID = oldest.id }
                return set
            }
    }

    // MARK: - Lower resolution (pHash match, different pixel area)

    private func findLowerResolution(in items: [MediaItem]) -> [DuplicateSet] {
        let candidates = items.filter { $0.perceptualHash != nil && $0.dimensions != nil }
        var sets: [DuplicateSet] = []
        var processed = Set<UUID>()

        for i in 0..<candidates.count {
            guard !processed.contains(candidates[i].id) else { continue }
            var group = [candidates[i]]

            for j in (i+1)..<candidates.count {
                guard !processed.contains(candidates[j].id) else { continue }
                guard hammingDistance(candidates[i].perceptualHash!, candidates[j].perceptualHash!) <= perceptualHashMaxDistance
                else { continue }
                // Only flag as lower-res if dimensions differ
                guard candidates[i].dimensions != candidates[j].dimensions else { continue }
                group.append(candidates[j])
            }

            if group.count > 1 {
                processed.formUnion(group.map(\.id))
                var set = DuplicateSet(kind: .lowerResolution, items: group)
                // Keep the highest resolution copy
                if let biggest = group.max(by: {
                    let a = $0.dimensions.map { $0.width * $0.height } ?? 0
                    let b = $1.dimensions.map { $0.width * $0.height } ?? 0
                    return a < b
                }) { set.keeperID = biggest.id }
                sets.append(set)
            }
        }
        return sets
    }

    // MARK: - Near-identical burst (pHash match + timestamps within 2 s)

    private func findBursts(in items: [MediaItem]) -> [DuplicateSet] {
        let candidates = items
            .filter { $0.perceptualHash != nil && $0.captureDate != nil }
            .sorted { $0.captureDate! < $1.captureDate! }

        var sets: [DuplicateSet] = []
        var processed = Set<UUID>()

        for i in 0..<candidates.count {
            guard !processed.contains(candidates[i].id) else { continue }
            var group = [candidates[i]]

            for j in (i+1)..<candidates.count {
                guard !processed.contains(candidates[j].id) else { continue }
                let dt = candidates[j].captureDate!.timeIntervalSince(candidates[i].captureDate!)
                guard dt <= burstTimeWindow else { break }
                guard hammingDistance(candidates[i].perceptualHash!, candidates[j].perceptualHash!) <= perceptualHashMaxDistance
                else { continue }
                group.append(candidates[j])
            }

            if group.count > 1 {
                processed.formUnion(group.map(\.id))
                // Bursts are kept in full (DuplicateKind.quarantinesCopies == false);
                // keeperID just marks the first shot for display.
                var set = DuplicateSet(kind: .nearIdenticalBurst, items: group)
                set.keeperID = group.first!.id
                sets.append(set)
            }
        }
        return sets
    }

    // MARK: - Helpers

    private func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
