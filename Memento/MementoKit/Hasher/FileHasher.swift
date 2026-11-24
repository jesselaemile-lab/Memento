import Foundation
import CommonCrypto
import CoreGraphics
import ImageIO
import AppKit

actor FileHasher {

    enum HashError: Error {
        case cannotOpen(URL)
        case readError
        case noImageData
    }

    // MARK: - SHA-256

    /// Stream-based SHA-256 using CommonCrypto — no XPC or hardware-token interactions.
    nonisolated func sha256(of url: URL) async throws -> String {
        guard let stream = InputStream(url: url) else { throw HashError.cannotOpen(url) }
        stream.open()
        defer { stream.close() }

        var ctx = CC_SHA256_CTX()
        CC_SHA256_Init(&ctx)

        let bufSize = 4_194_304  // 4 MB — fewer syscalls for large photo/video files
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: bufSize)
            if n < 0 { throw HashError.readError }
            if n == 0 { break }
            CC_SHA256_Update(&ctx, buf, CC_LONG(n))
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&digest, &ctx)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Perceptual hash (dHash)

    /// Difference hash over a 9×8 downscaled grayscale image → 64-bit fingerprint.
    /// Uses an embedded thumbnail rather than decoding the full image, keeping memory usage low.
    nonisolated func perceptualHash(of url: URL) async -> UInt64? {
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
        else { return nil }

        let w = 9, h = 8
        let bmi = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: bmi.rawValue
        ) else { return nil }

        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = ctx.data else { return nil }
        let p = pixels.bindMemory(to: UInt8.self, capacity: w * h)

        var hash: UInt64 = 0
        for row in 0..<h {
            for col in 0..<(w - 1) {
                let i = row * w + col
                if p[i] < p[i + 1] { hash |= 1 << (row * 8 + col) }
            }
        }
        return hash
    }

    // MARK: - Hamming distance

    func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - Batch

    /// - Parameter onProgress: called with (done, total, bytesHashed, bytesToHash).
    ///   `bytesToHash` is the byte sum of only the files actually being hashed (size-dedup
    ///   skips files whose size is unique in the batch — they can't be byte-identical duplicates).
    func hashBatch(
        _ items: [MediaItem],
        onProgress: @Sendable @escaping (Int, Int, Int64, Int64) -> Void
    ) async -> [UUID: String] {
        // Skip files whose size appears only once — they can never be byte-identical duplicates.
        var sizeCounts: [Int64: Int] = [:]
        for item in items { sizeCounts[item.fileSize, default: 0] += 1 }
        let candidates = items.filter { sizeCounts[$0.fileSize]! > 1 }
        let skipped = items.count - candidates.count
        let candidateBytes = candidates.reduce(0) { $0 + $1.fileSize }

        guard !candidates.isEmpty else {
            onProgress(items.count, items.count, 0, 0)
            return [:]
        }

        let concurrency = ProcessInfo.processInfo.activeProcessorCount
        return await withTaskGroup(of: (UUID, String, Int64)?.self) { group in
            var results: [UUID: String] = [:]
            var done = 0
            var bytesHashed: Int64 = 0
            var index = 0

            func enqueue() {
                guard index < candidates.count else { return }
                let item = candidates[index]; index += 1
                let size = item.fileSize
                group.addTask {
                    guard let hash = try? await self.sha256(of: item.url) else { return nil }
                    return (item.id, hash, size)
                }
            }
            for _ in 0..<min(concurrency, candidates.count) { enqueue() }

            for await result in group {
                if let (id, hash, size) = result {
                    results[id] = hash
                    bytesHashed += size
                }
                done += 1
                onProgress(skipped + done, items.count, bytesHashed, candidateBytes)
                enqueue()
            }
            return results
        }
    }
}
