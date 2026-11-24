import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct SourceView: View {
    @Environment(AppViewModel.self) private var vm

    @State private var sourceURLs: [URL] = []
    @State private var sourceStats: [URL: SourceStats] = [:]
    @State private var destinationURL: URL? = nil
    @State private var placementMode: PlacementMode = .move
    @State private var isDropTargeted = false

    private let folderTypes: [UTType] = [.folder, .volume]

    var body: some View {
        VStack(spacing: 0) {
            MScreenHeader("New run",
                          subtitle: "Point Memento at a messy folder or drive. It reads without writing anything until you approve the plan.")
            sourceForm
        }
    }

    private var sourceForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                dropZone
                if !sourceURLs.isEmpty { sourceQueue }
                destinationSection
                placementSection
                optionsSection
                footer
            }
            .padding(40)
            .frame(maxWidth: 840)
        }
        .background(Color.mGround)
        .onAppear { restoreLastDestination() }
    }

    // MARK: - Header

    // MARK: - Drop zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Color.mTerracotta : Color.mBorder,
                    style: StrokeStyle(lineWidth: 2, dash: [8, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(isDropTargeted ? Color.mTerracottaTint : Color.mSurface)
                )
                .animation(.easeInOut(duration: 0.15), value: isDropTargeted)

            VStack(spacing: 14) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Color.mTerracotta.opacity(0.8))
                VStack(spacing: 4) {
                    Text("Drop folders or drives here")
                        .font(.mSubheadSemi)
                        .foregroundStyle(Color.mText)
                    Text("or")
                        .font(.mBody)
                        .foregroundStyle(Color.mText.opacity(0.4))
                }
                MPillButton("Choose folder(s)…", icon: "folder", style: .secondary) {
                    pickFolder()
                }
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .onDrop(of: folderTypes, isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        addSource(url)
                    }
                }
            }
            return true
        }
    }

    // MARK: - Source queue

    private var sourceQueue: some View {
        VStack(alignment: .leading, spacing: 12) {
            MSectionHeader(title: "Sources (\(sourceURLs.count))")
            VStack(spacing: 6) {
                ForEach(sourceURLs, id: \.self) { url in
                    sourceRow(url: url)
                }
            }
        }
    }

    private func sourceRow(url: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: url.pathExtension.lowercased().isEmpty ? "folder.fill" : "externaldrive.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.mTerracotta)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.mBodySemi)
                    .foregroundStyle(Color.mText)
                Text(url.path)
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if let stats = sourceStats[url] {
                Text(stats.summary)
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.55))
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Counting…")
                        .font(.mCaption)
                        .foregroundStyle(Color.mText.opacity(0.4))
                }
            }

            Button {
                sourceURLs.removeAll { $0 == url }
                sourceStats[url] = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.mText.opacity(0.4))
                    .padding(6)
                    .background(Color.mText.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: url) {
            guard sourceStats[url] == nil else { return }
            let stats = await Task.detached(priority: .utility) {
                SourceStats.compute(for: url)
            }.value
            sourceStats[url] = stats
        }
    }

    // MARK: - Destination

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MSectionHeader(title: "Destination")
            HStack(spacing: 12) {
                if let dest = destinationURL {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(Color.mTerracotta)
                        Text(dest.path)
                            .font(.mBody)
                            .foregroundStyle(Color.mText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            destinationURL = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                                .foregroundStyle(Color.mText.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity)
                } else {
                    MPillButton("Choose destination…", icon: "folder.badge.plus", style: .secondary) {
                        pickDestination()
                    }
                }
            }

            if placementMode == .copy, let dest = destinationURL {
                freeSpaceNote(dest: dest)
            }
        }
    }

    private func freeSpaceNote(dest: URL) -> some View {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: dest.path)
        let free = (attrs?[.systemFreeSize] as? Int64) ?? 0
        return HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(Color.mText.opacity(0.5))
            Text("Available: \(free.formattedFileSize)")
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.5))
        }
    }

    // MARK: - Placement mode

    private var placementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MSectionHeader(title: "Placement")
            VStack(spacing: 6) {
                ForEach(PlacementMode.allCases) { mode in
                    placementRow(mode: mode)
                }
            }
        }
    }

    private func placementRow(mode: PlacementMode) -> some View {
        Button {
            placementMode = mode
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .strokeBorder(placementMode == mode ? Color.mTerracotta : Color.mBorder, lineWidth: 2)
                        .frame(width: 18, height: 18)
                    if placementMode == mode {
                        Circle().fill(Color.mTerracotta).frame(width: 10, height: 10)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.rawValue)
                        .font(.mBodySemi)
                        .foregroundStyle(Color.mText)
                    Text(mode.tagline)
                        .font(.mCaption)
                        .foregroundStyle(Color.mText.opacity(0.5))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                placementMode == mode ? Color.mTerracottaTint : Color.mSurface,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Options

    private var optionsSection: some View {
        // Bound straight to vm.rules so choices persist across sessions.
        @Bindable var vm = vm
        return VStack(alignment: .leading, spacing: 10) {
            MSectionHeader(title: "Scan options")
            VStack(spacing: 6) {
                mediaFilterRow(binding: $vm.rules.mediaFilter)
                optionToggle("Scan nested subfolders",
                             description: "Includes all folders inside your source, not just the top level.",
                             binding: $vm.rules.scanNestedSubfolders)
                optionToggle("Include sidecar files (XMP, AAE)",
                             description: "Keeps XMP and AAE edit files alongside their photos.",
                             binding: $vm.rules.includeSidecars)
                optionToggle("Include screenshots",
                             description: "Organizes screenshots into the library instead of skipping them.",
                             binding: $vm.rules.includeScreenshots)
                optionToggle("Follow symbolic links",
                             description: "Traverses symlinks as real folders. Avoid unless you know you need it.",
                             binding: $vm.rules.followSymlinks)
                optionToggle("On-device location reading",
                             description: "Reads GPS coordinates from EXIF to name events by place.",
                             binding: $vm.rules.enableLocationReading)
            }
        }
    }

    private func mediaFilterRow(binding: Binding<GroupingRules.MediaFilter>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("What to organize")
                    .font(.mBodySemi)
                    .foregroundStyle(Color.mText)
                Text("Photos only skips videos to save time and space — Live Photo clips stay with their photo.")
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.5))
            }
            Spacer()
            MSegmentedPicker(selection: binding,
                             options: GroupingRules.MediaFilter.allCases) { $0.rawValue }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func optionToggle(_ label: String, description: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.mBodySemi)
                    .foregroundStyle(Color.mText)
                Text(description)
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.5))
            }
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .tint(Color.mTerracotta)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            MPillButton(
                "Start scan",
                icon: "magnifyingglass",
                style: canStart ? .primary : .secondary
            ) {
                startScan()
            }
            .disabled(!canStart)
        }
    }

    // MARK: - Actions

    private var canStart: Bool { !sourceURLs.isEmpty && destinationURL != nil }

    private func startScan() {
        guard let dest = destinationURL, !sourceURLs.isEmpty else { return }
        // Options already live in vm.rules — the toggles bind to it directly.
        vm.startNewRun(sourceURLs: sourceURLs, destinationURL: dest, placementMode: placementMode)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add sources"
        if panel.runModal() == .OK {
            for url in panel.urls { addSource(url) }
        }
    }

    private func pickDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the destination folder for your organized library"
        if panel.runModal() == .OK, let url = panel.url {
            destinationURL = url
            saveLastDestination(url)
        }
    }

    // MARK: - Destination memory

    private static let lastDestinationKey = "lastDestinationBookmark"

    /// Persists the chosen destination as a security-scoped bookmark so the
    /// sandbox lets us pre-fill it (with access) on the next launch.
    private func saveLastDestination(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastDestinationKey)
    }

    private func restoreLastDestination() {
        guard destinationURL == nil,
              let data = UserDefaults.standard.data(forKey: Self.lastDestinationKey) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }
        // Access stays open for the app's lifetime so the scan/executor can
        // write to the destination; the sandbox reclaims it on quit.
        guard url.startAccessingSecurityScopedResource() else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            url.stopAccessingSecurityScopedResource()
            UserDefaults.standard.removeObject(forKey: Self.lastDestinationKey)
            return
        }
        if isStale { saveLastDestination(url) }
        destinationURL = url
    }

    private func addSource(_ url: URL) {
        guard !sourceURLs.contains(url) else { return }
        sourceURLs.append(url)
    }
}
// MARK: - Source folder quick stats

/// Fast pre-scan counts for a source folder, classified with the same
/// extension rules as MediaScanner so the numbers match a real scan.
nonisolated struct SourceStats: Sendable {
    var photos: Int = 0
    var videos: Int = 0
    var otherFiles: Int = 0
    var bytes: Int64 = 0

    var summary: String {
        var parts = ["\(photos) photos", "\(videos) videos"]
        if otherFiles > 0 { parts.append("\(otherFiles) other") }
        if bytes > 0 { parts.append(bytes.formattedFileSize) }
        return parts.joined(separator: " · ")
    }

    nonisolated static func compute(for url: URL) -> SourceStats {
        var stats = SourceStats()
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return stats }

        while let fileURL = enumerator.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            // Same managed-library rule as MediaScanner (safety rule 5)
            if ext == "photoslibrary" || ext == "lrlibrary" {
                enumerator.skipDescendants()
                continue
            }
            guard let resources = try? fileURL.resourceValues(forKeys: Set(keys)),
                  resources.isRegularFile == true else { continue }

            switch MediaItem.mediaType(for: ext) {
            case .photo, .rawPhoto, .livePhotoComponent:
                stats.photos += 1
                stats.bytes += Int64(resources.fileSize ?? 0)
            case .video:
                stats.videos += 1
                stats.bytes += Int64(resources.fileSize ?? 0)
            case .sidecar:
                stats.otherFiles += 1
            case nil:
                if !ext.isEmpty && ext != "ds_store" && ext != "localized" {
                    stats.otherFiles += 1
                }
            }
        }
        return stats
    }
}

