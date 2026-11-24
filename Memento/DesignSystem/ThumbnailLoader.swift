import SwiftUI
import ImageIO
import QuickLookThumbnailing

/// Shared, cached thumbnail loading for all grid/list cells.
///
/// Photos and RAW/HEIC files decode through ImageIO (fast, in-process — it can pull the
/// embedded JPEG preview without a full decode). Only videos and files ImageIO can't read
/// fall back to QuickLook, whose XPC round-trips are the expensive path we want to avoid
/// firing hundreds of times at once. Results are cached by (url, pixel size) so scrolling
/// and re-renders never reload the same thumbnail.
enum ThumbnailLoader {

    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 800
        return c
    }()

    /// Synchronous cache peek — lets a view show an already-loaded thumbnail on first render
    /// without a task hop or flash of placeholder.
    static func cached(_ url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    /// Loads a thumbnail, preferring the fast in-process path. `allowQuickLook` enables the
    /// video/unsupported fallback; pass `false` for photo-only grids to skip it entirely.
    static func load(url: URL, maxPixel: Int, allowQuickLook: Bool = true) async -> NSImage? {
        let k = key(url, maxPixel)
        if let hit = cache.object(forKey: k) { return hit }

        // Fast path: ImageIO thumbnail off the main thread.
        if let img = await Task.detached(priority: .utility, operation: {
            imageIOThumbnail(url: url, maxPixel: maxPixel)
        }).value {
            cache.setObject(img, forKey: k)
            return img
        }

        // Fallback: QuickLook (videos, or formats ImageIO rejects).
        guard allowQuickLook else { return nil }
        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1,
            representationTypes: .thumbnail
        )
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else {
            return nil
        }
        let img = rep.nsImage
        cache.setObject(img, forKey: k)
        return img
    }

    // MARK: - Private

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.absoluteString)#\(maxPixel)" as NSString
    }

    private nonisolated static func imageIOThumbnail(url: URL, maxPixel: Int) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }
}
