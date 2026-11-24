import Foundation

actor MediaScanner {

    struct ScanOptions: Sendable {
        var scanNestedSubfolders: Bool = true
        var followSymlinks: Bool       = false
        var includeSidecars: Bool      = true
        var includeScreenshots: Bool   = false
        var mediaFilter: GroupingRules.MediaFilter = .photosAndVideos
    }

    struct ScanProgress: Sendable {
        var foundItems: Int = 0
        var scannedDirectories: Int = 0
        var skippedItems: Int = 0
        var currentPath: String = ""
        var throughputBytesPerSecond: Double = 0
        var skippedManagedLibraries: [URL] = []
    }

    private let fileManager = FileManager.default

    /// Async stream of discovered MediaItems. Progress is delivered via onProgress callback.
    func scan(
        sourceURL: URL,
        options: ScanOptions = .init(),
        onProgress: @Sendable @escaping (ScanProgress) -> Void
    ) -> AsyncThrowingStream<MediaItem, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.walk(
                        url: sourceURL,
                        options: options,
                        onProgress: onProgress,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func walk(
        url: URL,
        options: ScanOptions,
        onProgress: @Sendable @escaping (ScanProgress) -> Void,
        continuation: AsyncThrowingStream<MediaItem, Error>.Continuation
    ) async throws {
        // Safety rule 5: refuse managed libraries.
        let ext = url.pathExtension.lowercased()
        if ext == "photoslibrary" || ext == "lrlibrary" {
            return
        }

        let keys: [URLResourceKey] = [
            .fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .creationDateKey, .isReadableKey
        ]
        let fmOptions: FileManager.DirectoryEnumerationOptions = options.followSymlinks
            ? [] : [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: fmOptions
        ) else { return }

        var progress = ScanProgress()
        var bytesScanned: Int64 = 0
        let startTime = Date()
        var lastReport = Date()

        while let fileURL = enumerator.nextObject() as? URL {
            try Task.checkCancellation()

            // Skip managed library bundles found mid-tree
            let itemExt = fileURL.pathExtension.lowercased()
            if itemExt == "photoslibrary" || itemExt == "lrlibrary" {
                enumerator.skipDescendants()
                progress.skippedManagedLibraries.append(fileURL)
                progress.skippedItems += 1
                continue
            }

            let resources = try? fileURL.resourceValues(forKeys: Set(keys))

            if resources?.isDirectory == true {
                if !options.scanNestedSubfolders && fileURL != url {
                    enumerator.skipDescendants()
                }
                progress.scannedDirectories += 1
                progress.currentPath = fileURL.lastPathComponent
                continue
            }

            guard resources?.isReadable == true else {
                progress.skippedItems += 1
                continue
            }

            guard let mediaType = MediaItem.mediaType(for: itemExt) else {
                if !itemExt.isEmpty && itemExt != "ds_store" && itemExt != "localized" {
                    progress.skippedItems += 1
                }
                continue
            }
            if mediaType == .sidecar && !options.includeSidecars { continue }
            if !Self.passesMediaFilter(options.mediaFilter, type: mediaType, url: fileURL) {
                progress.skippedItems += 1
                continue
            }

            let fileSize = Int64(resources?.fileSize ?? 0)
            var item = MediaItem(id: UUID(), url: fileURL, fileSize: fileSize, mediaType: mediaType)

            // The file's Date Created, exactly as Finder shows it (modified date only if the
            // volume doesn't record a creation date).
            if let fileDate = Self.fileCreatedDate(created: resources?.creationDate,
                                                    modified: resources?.contentModificationDate) {
                item.fileCreatedDate = fileDate
                item.captureDate = fileDate
                item.dateSource = .filesystem
            }

            // Screenshot detection by filename
            let lower = fileURL.deletingPathExtension().lastPathComponent.lowercased()
            if lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot") || lower.hasPrefix("screen recording") {
                item.isScreenshot = true
                if !options.includeScreenshots && mediaType == .photo { continue }
            }

            bytesScanned += fileSize
            progress.foundItems += 1

            let now = Date()
            if now.timeIntervalSince(lastReport) >= 0.15 {
                let elapsed = now.timeIntervalSince(startTime)
                if elapsed > 0 { progress.throughputBytesPerSecond = Double(bytesScanned) / elapsed }
                onProgress(progress)
                lastReport = now
            }

            continuation.yield(item)
        }

        onProgress(progress)
    }

    /// Applies the Photos-only / Videos-only choice. In Photos-only mode a video is still
    /// kept when it is the clip half of a Live Photo (same name as a sibling photo), so
    /// Live Photos stay whole; standalone videos are skipped.
    nonisolated static func passesMediaFilter(_ filter: GroupingRules.MediaFilter, type: MediaType, url: URL) -> Bool {
        switch filter {
        case .photosAndVideos:
            return true
        case .photosOnly:
            guard type == .video else { return true }
            let base = url.deletingPathExtension()
            return ["heic", "HEIC", "jpg", "JPG", "jpeg", "JPEG"].contains {
                FileManager.default.fileExists(atPath: base.appendingPathExtension($0).path)
            }
        case .videosOnly:
            return type == .video || type == .sidecar
        }
    }

    nonisolated static func fileCreatedDate(created: Date?, modified: Date?) -> Date? {
        created ?? modified
    }
}
