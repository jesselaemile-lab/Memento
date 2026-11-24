import Foundation
import CoreLocation

// CLLocationCoordinate2D is a plain C struct — safe to mark unchecked Sendable.
extension CLLocationCoordinate2D: @retroactive @unchecked Sendable {}

struct MediaItem: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let fileSize: Int64
    let mediaType: MediaType

    var captureDate: Date?
    var dateSource: DateSource = .filesystem
    /// The file's "Date Created" (earliest of creation/modification, see MediaScanner).
    var fileCreatedDate: Date?
    var location: CLLocationCoordinate2D?
    var locationName: String?
    var cameraModel: String?
    var dimensions: CGSize?
    var durationSeconds: Double?

    var sha256: String?
    var perceptualHash: UInt64?
    var faceCount: Int = 0

    var hasMissingEXIF: Bool = false
    var isScreenshot: Bool = false
    var pairedItemID: UUID?

    nonisolated init(id: UUID = UUID(), url: URL, fileSize: Int64, mediaType: MediaType) {
        self.id = id; self.url = url
        self.fileSize = fileSize; self.mediaType = mediaType
    }
}

// Codable by hand only because CLLocationCoordinate2D isn't Codable. Lets a plan be saved
// next to its journal so an interrupted run can be resumed after a relaunch.
extension MediaItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, url, fileSize, mediaType, captureDate, dateSource, fileCreatedDate, latitude, longitude,
             locationName, cameraModel, dimensions, durationSeconds, sha256, perceptualHash,
             faceCount, hasMissingEXIF, isScreenshot, pairedItemID
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  url: try c.decode(URL.self, forKey: .url),
                  fileSize: try c.decode(Int64.self, forKey: .fileSize),
                  mediaType: try c.decode(MediaType.self, forKey: .mediaType))
        captureDate     = try c.decodeIfPresent(Date.self, forKey: .captureDate)
        dateSource      = try c.decodeIfPresent(DateSource.self, forKey: .dateSource) ?? .filesystem
        fileCreatedDate = try c.decodeIfPresent(Date.self, forKey: .fileCreatedDate)
        if let lat = try c.decodeIfPresent(Double.self, forKey: .latitude),
           let lon = try c.decodeIfPresent(Double.self, forKey: .longitude) {
            location = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        locationName    = try c.decodeIfPresent(String.self, forKey: .locationName)
        cameraModel     = try c.decodeIfPresent(String.self, forKey: .cameraModel)
        dimensions      = try c.decodeIfPresent(CGSize.self, forKey: .dimensions)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        sha256          = try c.decodeIfPresent(String.self, forKey: .sha256)
        perceptualHash  = try c.decodeIfPresent(UInt64.self, forKey: .perceptualHash)
        faceCount       = try c.decodeIfPresent(Int.self, forKey: .faceCount) ?? 0
        hasMissingEXIF  = try c.decodeIfPresent(Bool.self, forKey: .hasMissingEXIF) ?? false
        isScreenshot    = try c.decodeIfPresent(Bool.self, forKey: .isScreenshot) ?? false
        pairedItemID    = try c.decodeIfPresent(UUID.self, forKey: .pairedItemID)
    }

    nonisolated func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(fileSize, forKey: .fileSize)
        try c.encode(mediaType, forKey: .mediaType)
        try c.encodeIfPresent(captureDate, forKey: .captureDate)
        try c.encode(dateSource, forKey: .dateSource)
        try c.encodeIfPresent(fileCreatedDate, forKey: .fileCreatedDate)
        try c.encodeIfPresent(location?.latitude, forKey: .latitude)
        try c.encodeIfPresent(location?.longitude, forKey: .longitude)
        try c.encodeIfPresent(locationName, forKey: .locationName)
        try c.encodeIfPresent(cameraModel, forKey: .cameraModel)
        try c.encodeIfPresent(dimensions, forKey: .dimensions)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(sha256, forKey: .sha256)
        try c.encodeIfPresent(perceptualHash, forKey: .perceptualHash)
        try c.encode(faceCount, forKey: .faceCount)
        try c.encode(hasMissingEXIF, forKey: .hasMissingEXIF)
        try c.encode(isScreenshot, forKey: .isScreenshot)
        try c.encodeIfPresent(pairedItemID, forKey: .pairedItemID)
    }
}

extension MediaItem {
    /// Same item at a new location — used once a run has moved the file.
    nonisolated func relocated(to newURL: URL) -> MediaItem {
        var copy = MediaItem(id: id, url: newURL, fileSize: fileSize, mediaType: mediaType)
        copy.captureDate = captureDate;       copy.dateSource = dateSource
        copy.fileCreatedDate = fileCreatedDate
        copy.location = location;             copy.locationName = locationName
        copy.cameraModel = cameraModel;       copy.dimensions = dimensions
        copy.durationSeconds = durationSeconds
        copy.sha256 = sha256;                 copy.perceptualHash = perceptualHash
        copy.faceCount = faceCount;           copy.hasMissingEXIF = hasMissingEXIF
        copy.isScreenshot = isScreenshot;     copy.pairedItemID = pairedItemID
        return copy
    }

    nonisolated var filename: String { url.lastPathComponent }
    nonisolated var fileExtension: String { url.pathExtension.lowercased() }
    nonisolated var effectiveCaptureDate: Date { captureDate ?? Date(timeIntervalSince1970: 0) }

    nonisolated static let photoExtensions: Set<String> = [
        "jpg","jpeg","heic","heif","png","gif","tiff","tif","bmp","webp"
    ]
    nonisolated static let rawExtensions: Set<String> = [
        "arw","cr2","cr3","nef","nrw","orf","rw2","dng","raf","pef","srw","x3f"
    ]
    nonisolated static let videoExtensions: Set<String> = [
        "mp4","mov","m4v","avi","mkv","mts","m2ts","wmv","3gp"
    ]
    nonisolated static let sidecarExtensions: Set<String> = ["xmp","thm","aae"]

    nonisolated static func mediaType(for ext: String) -> MediaType? {
        let e = ext.lowercased()
        if photoExtensions.contains(e)   { return .photo }
        if rawExtensions.contains(e)     { return .rawPhoto }
        if videoExtensions.contains(e)   { return .video }
        if sidecarExtensions.contains(e) { return .sidecar }
        return nil
    }
}

enum MediaType: String, Sendable, Codable, CaseIterable {
    case photo, video, rawPhoto, sidecar, livePhotoComponent
}

enum DateSource: String, Sendable, Codable {
    case exif, videoMetadata, filesystem, userProvided
}
