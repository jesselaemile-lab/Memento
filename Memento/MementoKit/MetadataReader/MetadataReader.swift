import Foundation
import ImageIO
import AVFoundation
import CoreLocation

actor MetadataReader {

    private let dateParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    func read(_ item: MediaItem) async -> MediaItem {
        var updated = item
        switch item.mediaType {
        case .photo, .rawPhoto:
            readImageMetadata(into: &updated)
        case .video, .livePhotoComponent:
            await readVideoMetadata(into: &updated)
        case .sidecar:
            break
        }
        return updated
    }

    /// Read up to maxConcurrent items concurrently via a TaskGroup.
    /// Each child task creates its own MetadataReader so reads run in true parallel
    /// rather than serializing on this actor's executor.
    func readBatch(_ items: [MediaItem], concurrency: Int = ProcessInfo.processInfo.activeProcessorCount) async -> [MediaItem] {
        await withTaskGroup(of: MediaItem.self) { group in
            var results: [MediaItem] = []
            results.reserveCapacity(items.count)
            var index = 0

            func enqueue() {
                guard index < items.count else { return }
                let item = items[index]; index += 1
                group.addTask { await MetadataReader().read(item) }
            }

            for _ in 0..<min(concurrency, items.count) { enqueue() }

            for await result in group {
                results.append(result)
                enqueue()
            }
            return results
        }
    }

    // MARK: - Image

    private func readImageMetadata(into item: inout MediaItem) {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(item.url as CFURL, options as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            item.hasMissingEXIF = true
            return
        }

        // EXIF date
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            let dateStr = (exif[kCGImagePropertyExifDateTimeOriginal]
                        ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String
            let offset = (exif[kCGImagePropertyExifOffsetTimeOriginal]
                       ?? exif[kCGImagePropertyExifOffsetTime]) as? String
            if let dateStr, let date = Self.exifDate(dateStr, offset: offset, parser: dateParser) {
                item.captureDate = date
                item.dateSource = .exif
            } else {
                item.hasMissingEXIF = true
            }
        } else {
            item.hasMissingEXIF = true
        }

        // GPS
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            item.location = parseGPS(gps)
        }

        // Camera
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make  = tiff[kCGImagePropertyTIFFMake]  as? String ?? ""
            let model = tiff[kCGImagePropertyTIFFModel] as? String ?? ""
            let joined = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
            if !joined.isEmpty { item.cameraModel = joined }
        }

        // Dimensions
        if let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0 {
            item.dimensions = CGSize(width: w, height: h)
        }
    }

    // MARK: - Video

    private func readVideoMetadata(into item: inout MediaItem) async {
        let asset = AVURLAsset(url: item.url)

        if let dur = try? await asset.load(.duration), dur.isNumeric {
            item.durationSeconds = dur.seconds
        }

        if let metadata = try? await asset.load(.commonMetadata) {
            for meta in metadata where meta.commonKey == .commonKeyCreationDate {
                if let date = try? await meta.load(.value) as? Date {
                    item.captureDate = date; item.dateSource = .videoMetadata; break
                }
                if let str = try? await meta.load(.value) as? String {
                    let parsed = dateParser.date(from: str)
                              ?? ISO8601DateFormatter().date(from: str)
                    if let parsed {
                        item.captureDate = parsed; item.dateSource = .videoMetadata; break
                    }
                }
            }
        }

        if item.captureDate == nil { item.hasMissingEXIF = true }
    }

    // MARK: - Helpers

    /// EXIF times are wall-clock times; with OffsetTimeOriginal ("+02:00") we can place
    /// them exactly instead of assuming this Mac's time zone.
    nonisolated static func exifDate(_ str: String, offset: String?, parser: DateFormatter) -> Date? {
        if let offset, offset.count == 6 {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let d = f.date(from: str + offset) { return d }
        }
        return parser.date(from: str)
    }

    private func parseGPS(_ gps: [CFString: Any]) -> CLLocationCoordinate2D? {
        guard let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef]  as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
        return CLLocationCoordinate2D(
            latitude:  latRef == "S" ? -lat : lat,
            longitude: lonRef == "W" ? -lon : lon
        )
    }
}
