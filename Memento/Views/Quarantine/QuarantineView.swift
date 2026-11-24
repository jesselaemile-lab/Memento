import SwiftUI
import AppKit

struct QuarantineView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var items: [QuarantineFileItem] = []
    @State private var isLoading: Bool = false
    @State private var showTrashConfirm: Bool = false
    @State private var trashError: String?

    struct QuarantineFileItem: Identifiable {
        let id = UUID()
        let url: URL
        let fileSize: Int64
        let isVideo: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            qHeader
            if isLoading {
                VStack { ProgressView("Scanning quarantine folder…") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mGround)
            } else if items.isEmpty && appVM.quarantineURL == nil {
                EmptyState(
                    icon: "archivebox",
                    title: "No quarantine folder",
                    message: "Apply a plan with duplicates to create the quarantine folder."
                )
            } else if items.isEmpty {
                EmptyState(
                    icon: "archivebox",
                    title: "Quarantine is empty",
                    message: "All duplicate copies have been restored or permanently removed."
                )
            } else {
                actionBar
                Rectangle().fill(Color.mBorder).frame(height: 1)
                fileList
            }
        }
        .background(Color.mGround)
        .task { await scan() }
        .alert("Couldn't move to Trash", isPresented: Binding(
            get: { trashError != nil }, set: { if !$0 { trashError = nil } }
        )) {
            Button("OK") { trashError = nil }
        } message: { Text(trashError ?? "") }
    }

    // MARK: - Header

    private var qHeader: some View {
        MScreenHeader("Quarantine", subtitle: "Memento never empties this folder automatically — you decide when to act.") {
            if !items.isEmpty {
                Text("\(items.count) files · \(totalSize.formattedFileSize)")
                    .font(.mLabel)
                    .foregroundStyle(Color.mText.opacity(0.5))
            }
        }
    }

    private var totalSize: Int64 { items.reduce(0) { $0 + $1.fileSize } }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            MPillButton("Move all to Trash", icon: "trash", style: .secondary) {
                showTrashConfirm = true
            }
            Text("Files go to Trash — recoverable from there.")
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.45))
            Spacer()
            if let dir = appVM.quarantineURL {
                MPillButton("Show in Finder", icon: "folder", style: .ghost) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.mSurface)
        .confirmationDialog(
            "Move \(items.count) file\(items.count == 1 ? "" : "s") to Trash?",
            isPresented: $showTrashConfirm,
            titleVisibility: .visible
        ) {
            Button("Move to Trash") { trashAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Files are recoverable from Trash. Memento will never delete them permanently.")
        }
    }

    // MARK: - File list

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(items) { item in
                    fileRow(item)
                    Rectangle().fill(Color.mBorder).frame(height: 1).padding(.leading, 20)
                }
            }
        }
        .background(Color.mGround)
    }

    private func fileRow(_ item: QuarantineFileItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.isVideo ? "video" : "photo")
                .foregroundStyle(Color.mText.opacity(0.35))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.mBodySemi)
                    .foregroundStyle(Color.mText)
                    .lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer()

            Text(item.fileSize.formattedFileSize)
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.55))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func scan() async {
        guard let dir = appVM.quarantineURL else { return }
        isLoading = true
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: keys) else {
            isLoading = false; return
        }
        var result: [QuarantineFileItem] = []
        while let url = enumerator.nextObject() as? URL {
            let res = try? url.resourceValues(forKeys: Set(keys))
            if res?.isDirectory == true { continue }
            let size = Int64(res?.fileSize ?? 0)
            let ext  = url.pathExtension.lowercased()
            result.append(QuarantineFileItem(url: url, fileSize: size, isVideo: MediaItem.videoExtensions.contains(ext)))
        }
        items = result
        isLoading = false
    }

    private func trashAll() {
        let urls = items.map(\.url)
        NSWorkspace.shared.recycle(urls) { _, error in
            Task { @MainActor in
                // Recount from disk rather than assume success — a locked file may remain.
                await appVM.refreshQuarantineCount()
                await scan()
                if let error { trashError = error.localizedDescription }
            }
        }
    }
}
