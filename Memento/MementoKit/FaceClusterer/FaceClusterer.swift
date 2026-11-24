import Foundation
import Vision
import ImageIO

// MARK: - Result types

/// One face found in one photo.
struct DetectedFace: Sendable, Codable {
    let itemID: UUID
    /// Normalized bounding box (Vision coordinates: origin at lower-left).
    let boundingBox: CGRect
    /// L2-normalized feature print of the face crop; nil when the face was too small to describe.
    let embedding: [Float]?

    /// Share of the frame the face covers — used to pick the main person in group photos.
    nonisolated var area: CGFloat { boundingBox.width * boundingBox.height }
}

struct FaceDetectionResult: Sendable {
    let itemID: UUID
    let faces: [DetectedFace]
    nonisolated var faceCount: Int { faces.count }
}

struct FaceCluster: Identifiable, Sendable {
    let id: UUID
    var name: String?
    var faces: [DetectedFace]
    var sampleItems: [MediaItem]

    nonisolated var isNamed: Bool { !(name ?? "").isEmpty }
    /// Number of distinct photos this person appears in.
    nonisolated var totalItemCount: Int { Set(faces.map(\.itemID)).count }
    /// The largest face of this person, used for the avatar crop.
    nonisolated var bestFace: DetectedFace? { faces.max { $0.area < $1.area } }

    nonisolated init(id: UUID = UUID(), name: String? = nil, faces: [DetectedFace], sampleItems: [MediaItem]) {
        self.id = id; self.name = name
        self.faces = faces; self.sampleItems = sampleItems
    }

    /// Mean of this person's face embeddings, L2-normalized.
    nonisolated var centroid: [Float]? {
        let embs = faces.compactMap(\.embedding)
        guard let first = embs.first else { return nil }
        var sum = [Float](repeating: 0, count: first.count)
        for e in embs where e.count == sum.count { for k in sum.indices { sum[k] += e[k] } }
        let norm = sum.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? sum.map { $0 / norm } : nil
    }
}

/// On-disk form of a named person, so names survive relaunches and seed the next scan.
struct PersonRecord: Codable, Sendable {
    let id: UUID
    var name: String
    var faces: [DetectedFace]
    var sampleURLs: [URL]

    /// Keeps the largest faces so the file stays small while the centroid stays representative.
    nonisolated static let maxStoredFaces = 200

    nonisolated init(cluster: FaceCluster) {
        id = cluster.id
        name = cluster.name ?? ""
        faces = Array(cluster.faces.sorted { $0.area > $1.area }.prefix(Self.maxStoredFaces))
        sampleURLs = cluster.sampleItems.map(\.url)
    }

    nonisolated var cluster: FaceCluster {
        FaceCluster(
            id: id, name: name, faces: faces,
            sampleItems: sampleURLs.map { MediaItem(url: $0, fileSize: 0, mediaType: .photo) }
        )
    }
}

// MARK: - FaceClusterer

actor FaceClusterer {

    /// Longest edge of the image used for detection and face crops.
    private nonisolated static let analysisPixelSize = 1024
    /// Faces smaller than this (in analysis pixels) are counted but not identified.
    private nonisolated static let minFacePixels: CGFloat = 48

    // MARK: - Single item detection

    nonisolated func detectFaces(in item: MediaItem) async -> FaceDetectionResult {
        // CGImageSource can pull the embedded JPEG preview from RAW/HEIC files directly —
        // much faster than a full decode.
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.analysisPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(item.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
        else {
            return FaceDetectionResult(itemID: item.id, faces: [])
        }

        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            let observations = request.results ?? []
            let faces = observations.map { obs in
                DetectedFace(
                    itemID: item.id,
                    boundingBox: obs.boundingBox,
                    embedding: Self.embedding(for: obs.boundingBox, in: image)
                )
            }
            return FaceDetectionResult(itemID: item.id, faces: faces)
        } catch {
            return FaceDetectionResult(itemID: item.id, faces: [])
        }
    }

    /// Crops the face (with some margin) and generates a Vision feature print for it.
    /// Feature prints are generic image descriptors, not a dedicated face-identity model,
    /// so they work best on reasonably large, front-facing faces.
    private nonisolated static func embedding(for box: CGRect, in image: CGImage) -> [Float]? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision boxes are normalized with a lower-left origin; CGImage crops use top-left.
        var rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        guard rect.width >= minFacePixels, rect.height >= minFacePixels else { return nil }
        rect = rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.2)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let crop = image.cropping(to: rect.integral) else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        guard (try? handler.perform([request])) != nil,
              let print = request.results?.first else { return nil }
        return normalized(vector(from: print))
    }

    private nonisolated static func vector(from print: VNFeaturePrintObservation) -> [Float] {
        let count = print.elementCount
        return print.data.withUnsafeBytes { raw in
            switch print.elementType {
            case .double: return raw.bindMemory(to: Double.self).prefix(count).map { Float($0) }
            default:      return Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        }
    }

    // MARK: - Batch detection

    func detectBatch(
        _ items: [MediaItem],
        onProgress: @Sendable @escaping (Int, Int) -> Void
    ) async -> [UUID: FaceDetectionResult] {
        let concurrency = ProcessInfo.processInfo.activeProcessorCount
        return await withTaskGroup(of: FaceDetectionResult.self) { group in
            var results: [UUID: FaceDetectionResult] = [:]
            var done = 0; var index = 0

            func enqueue() {
                guard index < items.count else { return }
                let item = items[index]; index += 1
                group.addTask { await self.detectFaces(in: item) }
            }

            for _ in 0..<min(concurrency, items.count) { enqueue() }
            for await result in group {
                results[result.itemID] = result
                done += 1; onProgress(done, items.count)
                enqueue()
            }
            return results
        }
    }

    // MARK: - Clustering

    /// Groups faces into people using greedy nearest-centroid clustering on feature prints.
    /// `matchDistance` is the largest Euclidean distance (between normalized vectors) at which
    /// a face still joins an existing person; lower values are stricter. `knownPeople` (named
    /// clusters from earlier runs) seed the clusters so returning faces keep their names.
    func cluster(
        items: [MediaItem],
        faceResults: [UUID: FaceDetectionResult],
        matchDistance: Float,
        knownPeople: [FaceCluster] = []
    ) -> [FaceCluster] {
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let faces = faceResults.values
            .flatMap(\.faces)
            .filter { $0.embedding != nil }
            // Larger faces first so each cluster's centroid is seeded by a clear face.
            .sorted { $0.area > $1.area }

        var centroids: [[Float]] = []
        var members: [[DetectedFace]] = []
        var seeds: [FaceCluster?] = []   // known person a cluster was seeded from, if any
        for person in knownPeople {
            guard let c = person.centroid else { continue }
            centroids.append(c); members.append([]); seeds.append(person)
        }

        for face in faces {
            guard let emb = face.embedding else { continue }
            var bestIndex = -1
            var bestDistance = Float.greatestFiniteMagnitude
            for (i, c) in centroids.enumerated() {
                let d = Self.distance(emb, c)
                if d < bestDistance { bestDistance = d; bestIndex = i }
            }
            if bestIndex >= 0, bestDistance <= matchDistance {
                members[bestIndex].append(face)
                // Running mean keeps the centroid representative as the cluster grows.
                let n = Float(members[bestIndex].count)
                var c = centroids[bestIndex]
                for k in c.indices { c[k] += (emb[k] - c[k]) / n }
                centroids[bestIndex] = Self.normalized(c)
            } else {
                centroids.append(emb)
                members.append([face])
                seeds.append(nil)
            }
        }

        return zip(members, seeds)
            .compactMap { faces, seed -> FaceCluster? in
                let sampleIDs = faces.sorted { $0.area > $1.area }.map(\.itemID)
                var seen = Set<UUID>()
                let samples = sampleIDs.filter { seen.insert($0).inserted }.prefix(5).compactMap { itemsByID[$0] }
                if let seed {
                    // Known person: keep id/name, carry their history, prefer fresh samples.
                    guard !faces.isEmpty else { return nil }
                    return FaceCluster(id: seed.id, name: seed.name, faces: seed.faces + faces,
                                       sampleItems: Array((samples + seed.sampleItems).prefix(5)))
                }
                return FaceCluster(faces: faces, sampleItems: Array(samples))
            }
            .sorted { $0.totalItemCount > $1.totalItemCount }
    }

    // MARK: - Vector math

    private nonisolated static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    private nonisolated static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return .greatestFiniteMagnitude }
        var sum: Float = 0
        for i in a.indices { let d = a[i] - b[i]; sum += d * d }
        return sum.squareRoot()
    }
}

// MARK: - People assignment

enum PeopleAssigner {
    /// Maps each photo to the name of its main person: the named person with the largest
    /// face in the frame. Paired companions (Live Photo video, RAW/JPEG) follow their primary.
    nonisolated static func personByItem(clusters: [FaceCluster], items: [MediaItem]) -> [UUID: String] {
        var best: [UUID: (name: String, area: CGFloat)] = [:]
        for cluster in clusters {
            guard let name = cluster.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
            else { continue }
            for face in cluster.faces where face.area > (best[face.itemID]?.area ?? 0) {
                best[face.itemID] = (name, face.area)
            }
        }
        var result = best.mapValues(\.name)
        for item in items {
            guard let companion = item.pairedItemID else { continue }
            if let name = result[item.id], result[companion] == nil { result[companion] = name }
            if let name = result[companion], result[item.id] == nil { result[item.id] = name }
        }
        return result
    }
}
