import Foundation

// MARK: - Progress snapshot

struct ExecutionProgress: Sendable {
    var completed: Int = 0
    var total: Int = 0
    var failed: Int = 0
    var quarantined: Int = 0
    /// Files that already existed at the destination with identical content.
    var alreadyPresent: Int = 0
    var bytesTransferred: Int64 = 0
    var currentFile: String = ""
    var throughputBytesPerSecond: Double = 0
    var lastCheckpointToken: String = ""

    nonisolated init() {}
    nonisolated var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

// MARK: - Volume check

enum VolumeCheck {
    /// True when both URLs live on the same volume, so a move is a metadata-only rename.
    nonisolated static func sameVolume(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b,
              let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return false }
        return va.isEqual(vb)
    }
}

// MARK: - Executor

actor Executor {

    enum ExecutorError: Error {
        case checksumMismatch(source: URL, dest: URL)
        case insufficientSpace
        case hardlinkCrossVolume
    }

    /// What an earlier, interrupted attempt already did — derived from its journal.
    struct ResumeState: Sendable {
        /// source path → the completed copy entry (dest path + checksum)
        var completedCopies: [String: JournalEntry] = [:]
        var removedSources: Set<String> = []
        var quarantinedSources: Set<String> = []

        nonisolated init() {}

        nonisolated init(entries: [JournalEntry]) {
            for e in entries where e.status == .completed {
                switch e.op {
                case .copy:         completedCopies[e.sourcePath] = e
                case .removeSource: removedSources.insert(e.sourcePath)
                case .quarantine:   quarantinedSources.insert(e.sourcePath)
                case .checkpoint:   break
                }
            }
        }
    }

    private var isPaused = false
    private let checkpointInterval: TimeInterval

    init(checkpointInterval: TimeInterval = 30) {
        self.checkpointInterval = checkpointInterval
    }

    func execute(
        plan: OrganizationPlan,
        journal: JournalStore,
        resuming state: ResumeState? = nil,
        onProgress: @Sendable @escaping (ExecutionProgress) -> Void
    ) async throws {
        let fm = FileManager.default
        let hasher = FileHasher()

        // Free-space check for Copy mode
        if plan.placementMode == .copy {
            let needed = plan.totalSize
            let attrs = try fm.attributesOfFileSystem(forPath: plan.destinationURL.path)
            let free = (attrs[.systemFreeSize] as? Int64) ?? 0
            guard free > needed else { throw ExecutorError.insufficientSpace }
        }

        // Hardlink cross-volume check
        if plan.placementMode == .hardlink {
            let srcAttrs = plan.sourceURLs.first.flatMap { try? FileManager.default.attributesOfFileSystem(forPath: $0.path) }
            let srcVol = srcAttrs?[.systemNumber] as? Int
            let dstAttrs = try? FileManager.default.attributesOfFileSystem(forPath: plan.destinationURL.path)
            let dstVol = dstAttrs?[.systemNumber] as? Int
            guard srcVol == dstVol else { throw ExecutorError.hardlinkCrossVolume }
        }

        // Quarantine dir for duplicates
        let quarantineDir = plan.destinationURL
            .appendingPathComponent("_Duplicates (quarantine)", isDirectory: true)

        var progress = ExecutionProgress()
        progress.total = plan.totalItems + plan.duplicateSets.flatMap(\.quarantined).count
        var lastCheckpoint = Date()

        // Execute planned folders
        for folder in plan.proposedFolders {
            let folderURL = plan.destinationURL.appendingPathComponent(folder.relativePath, isDirectory: true)
            try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

            for item in folder.items {
                try Task.checkCancellation()
                while isPaused { try await Task.sleep(nanoseconds: 500_000_000) }

                let destName = resolvedName(for: item, conflicts: folder.conflicts)
                let destURL  = folderURL.appendingPathComponent(destName)

                progress.currentFile = item.filename

                // Resume: skip files an earlier attempt already copied and verified. In Move
                // mode a copy may have completed without the source being released yet —
                // re-verify the destination before removing it (Safety rule 2 still holds).
                if let state, let prior = state.completedCopies[item.url.path],
                   let priorDest = prior.destPath, fm.fileExists(atPath: priorDest) {
                    if plan.placementMode == .move,
                       !state.removedSources.contains(item.url.path),
                       fm.fileExists(atPath: item.url.path) {
                        let destHash = try? await hasher.sha256(of: URL(fileURLWithPath: priorDest))
                        if let destHash, destHash == prior.sha256 {
                            try? fm.removeItem(at: item.url)
                            var entry = prior; entry.op = .removeSource
                            entry.timestamp = Date().timeIntervalSince1970
                            try? await journal.append(entry)
                        } else {
                            progress.failed += 1
                            onProgress(progress)
                            continue
                        }
                    }
                    progress.completed += 1
                    progress.bytesTransferred += item.fileSize
                    onProgress(progress)
                    continue
                }

                // Appending into an existing library: if this exact file is already there
                // (same name AND same bytes), don't create "IMG_1 (2)". Move → the source is a
                // duplicate and goes to quarantine; Copy/Hardlink → nothing to do.
                if fm.fileExists(atPath: destURL.path),
                   await isIdentical(item, to: destURL, hasher: hasher) {
                    if plan.placementMode == .move {
                        try? fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
                        let qDest = uniqueDest(quarantineDir.appendingPathComponent(item.filename), fm: fm)
                        do {
                            try fm.moveItem(at: item.url, to: qDest)
                            try await journal.append(JournalEntry(
                                runID: plan.runID.uuidString, checkpointID: nil,
                                sourcePath: item.url.path, destPath: qDest.path, sha256: item.sha256,
                                bytes: item.fileSize, timestamp: Date().timeIntervalSince1970,
                                op: .quarantine, status: .completed))
                            progress.quarantined += 1
                        } catch { progress.failed += 1 }
                    }
                    progress.alreadyPresent += 1
                    progress.completed += 1
                    onProgress(progress)
                    continue
                }

                do {
                    try await transferFile(
                        item: item, dest: destURL,
                        mode: plan.placementMode,
                        hasher: hasher, journal: journal,
                        runID: plan.runID, fm: fm
                    )
                    progress.completed += 1
                    progress.bytesTransferred += item.fileSize
                } catch ExecutorError.checksumMismatch(let src, let dst) {
                    // Safety rule 2: mismatch aborts this file — never remove source
                    progress.failed += 1
                    try? fm.removeItem(at: dst)  // clean up partial dest
                    let entry = JournalEntry(
                        runID: plan.runID.uuidString, checkpointID: nil,
                        sourcePath: src.path, destPath: dst.path, sha256: nil,
                        bytes: item.fileSize, timestamp: Date().timeIntervalSince1970,
                        op: .copy, status: .failed
                    )
                    try? await journal.append(entry)
                } catch {
                    progress.failed += 1
                }

                // Checkpoint every 30s
                let now = Date()
                if now.timeIntervalSince(lastCheckpoint) >= checkpointInterval {
                    let token = "cp-\(progress.completed)-\(Int(now.timeIntervalSince1970))"
                    try? await journal.writeCheckpoint(
                        runID: plan.runID, token: token,
                        itemsCompleted: progress.completed,
                        bytesCompleted: progress.bytesTransferred
                    )
                    progress.lastCheckpointToken = token
                    lastCheckpoint = now
                }

                onProgress(progress)
            }
        }

        // Quarantine duplicates
        try? fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        for set in plan.duplicateSets {
            for item in set.quarantined {
                try Task.checkCancellation()
                if let state, state.quarantinedSources.contains(item.url.path) {
                    progress.quarantined += 1
                    onProgress(progress)
                    continue
                }
                // Journal the path actually used (may carry a "(2)" suffix) so revert can find it.
                let dest = uniqueDest(quarantineDir.appendingPathComponent(item.filename), fm: fm)
                do {
                    try fm.moveItem(at: item.url, to: dest)
                    let entry = JournalEntry(
                        runID: plan.runID.uuidString, checkpointID: nil,
                        sourcePath: item.url.path, destPath: dest.path, sha256: item.sha256,
                        bytes: item.fileSize, timestamp: Date().timeIntervalSince1970,
                        op: .quarantine, status: .completed
                    )
                    try await journal.append(entry)
                    progress.quarantined += 1
                } catch { progress.failed += 1 }
                onProgress(progress)
            }
        }
    }

    func pause()  { isPaused = true }
    func resume() { isPaused = false }

    // MARK: - File transfer (Safety rule 2: verify before releasing source)

    private func transferFile(
        item: MediaItem, dest: URL,
        mode: PlacementMode,
        hasher: FileHasher,
        journal: JournalStore,
        runID: UUID,
        fm: FileManager
    ) async throws {
        let destURL = uniqueDest(dest, fm: fm)

        // Fast path: moving within one volume is an atomic rename — the bytes never move,
        // so there is nothing to copy or re-verify. Journal it as copy + removeSource so
        // revert and resume treat it like any other move.
        if mode == .move, VolumeCheck.sameVolume(item.url, dest.deletingLastPathComponent()) {
            try fm.moveItem(at: item.url, to: destURL)
            var entry = JournalEntry(
                runID: runID.uuidString, checkpointID: nil,
                sourcePath: item.url.path, destPath: destURL.path,
                sha256: item.sha256, bytes: item.fileSize,
                timestamp: Date().timeIntervalSince1970,
                op: .copy, status: .completed
            )
            try await journal.append(entry)
            entry.op = .removeSource
            try await journal.append(entry)
            return
        }

        switch mode {
        case .move, .copy:
            // 1. Copy to destination
            try fm.copyItem(at: item.url, to: destURL)

            // 2. Verify checksum (Safety rule 2)
            async let srcHash = hasher.sha256(of: item.url)
            async let dstHash = hasher.sha256(of: destURL)
            let (sh, dh) = try await (srcHash, dstHash)
            guard sh == dh else {
                throw ExecutorError.checksumMismatch(source: item.url, dest: destURL)
            }

            // 3. Journal the copy as completed
            var entry = JournalEntry(
                runID: runID.uuidString, checkpointID: nil,
                sourcePath: item.url.path, destPath: destURL.path,
                sha256: sh, bytes: item.fileSize,
                timestamp: Date().timeIntervalSince1970,
                op: .copy, status: .completed
            )
            try await journal.append(entry)

            // 4. Only now remove source (Move mode only)
            if mode == .move {
                try fm.removeItem(at: item.url)
                entry.op = .removeSource
                try await journal.append(entry)
            }

        case .hardlink:
            try fm.linkItem(at: item.url, to: destURL)
            let entry = JournalEntry(
                runID: runID.uuidString, checkpointID: nil,
                sourcePath: item.url.path, destPath: destURL.path,
                sha256: item.sha256, bytes: 0,
                timestamp: Date().timeIntervalSince1970,
                op: .copy, status: .completed
            )
            try await journal.append(entry)
        }
    }

    // MARK: - Helpers

    /// Same size and same SHA-256 as the file already at `dest`.
    private func isIdentical(_ item: MediaItem, to dest: URL, hasher: FileHasher) async -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
              (attrs[.size] as? Int64) == item.fileSize else { return false }
        guard let destHash = try? await hasher.sha256(of: dest) else { return false }
        let srcHash: String?
        if let known = item.sha256 { srcHash = known } else { srcHash = try? await hasher.sha256(of: item.url) }
        return srcHash == destHash
    }

    private func resolvedName(for item: MediaItem, conflicts: [FilenameConflict]) -> String {
        conflicts.first { $0.originalName == item.filename }?.resolvedName ?? item.filename
    }

    /// Suffix (2), (3)... if the path already exists (Safety rule 6: never overwrite).
    private func uniqueDest(_ url: URL, fm: FileManager) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext  = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir  = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
