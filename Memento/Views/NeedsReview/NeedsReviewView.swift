import SwiftUI

struct NeedsReviewView: View {
    @Environment(AppViewModel.self) private var vm

    enum ReviewTab: String, CaseIterable {
        case noDate       = "No date"
        case ambiguous    = "Ambiguous event"
        case unreadable   = "Unreadable"
    }

    @State private var tab: ReviewTab = .noDate
    @State private var selectedIDs: Set<UUID> = []
    @State private var focusedItemID: UUID?
    @State private var proposedDate: Date = Date()
    @State private var proposedFolderName: String = ""

    private var items: [MediaItem] {
        switch tab {
        case .noDate:
            return vm.needsReviewItems.filter { $0.captureDate == nil }
        case .ambiguous:
            return vm.needsReviewItems.filter { $0.captureDate != nil && $0.hasMissingEXIF }
        case .unreadable:
            return vm.needsReviewItems.filter { !$0.hasMissingEXIF && $0.captureDate == nil }
        }
    }

    private var focused: MediaItem? {
        guard let id = focusedItemID else { return nil }
        return items.first { $0.id == id }
    }

    private let thumbColumns = [GridItem(.adaptive(minimum: 90, maximum: 110), spacing: 4)]

    var body: some View {
        VStack(spacing: 0) {
            MScreenHeader("Needs review", subtitle: vm.needsReviewItems.isEmpty ? nil
                : "\(vm.needsReviewItems.count) items need a decision")
            reviewContent
        }
    }

    @ViewBuilder
    private var reviewContent: some View {
        if vm.needsReviewItems.isEmpty {
            EmptyState(
                icon: "questionmark.circle",
                title: "Nothing needs review",
                message: "Memento was able to date and place all items in this run."
            )
        } else {
            VStack(spacing: 0) {
                topBar
                MDivider()
                HStack(spacing: 0) {
                    leftGrid
                        .frame(width: 300)
                    MDivider().frame(width: 1)
                    rightInspector
                }
            }
            .background(Color.mGround)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 16) {
            MSegmentedPicker(selection: $tab, options: ReviewTab.allCases) {
                "\($0.rawValue) (\(countFor($0)))"
            }

            Spacer()

            // Suggestion
            if !selectedIDs.isEmpty {
                Text("\(selectedIDs.count) selected")
                    .font(.mLabel)
                    .foregroundStyle(Color.mText.opacity(0.6))
            }

            MPillButton(
                "Apply to \(selectedIDs.isEmpty ? "all" : "\(selectedIDs.count)")",
                icon: "checkmark",
                style: .primary
            ) {
                applyToSelected()
            }
            .disabled(items.isEmpty || vm.planVM == nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.mSurface)
    }

    // MARK: - Left grid

    private var leftGrid: some View {
        VStack(spacing: 0) {
            if let suggestion = buildSuggestion() {
                suggestionPanel(suggestion)
                MDivider()
            }

            ScrollView {
                LazyVGrid(columns: thumbColumns, spacing: 4) {
                    ForEach(items) { item in
                        ReviewThumbnailCell(
                            item: item,
                            isSelected: selectedIDs.contains(item.id),
                            isFocused: focusedItemID == item.id
                        ) {
                            toggleSelect(item)
                        }
                    }
                }
                .padding(12)
            }
        }
        .background(Color.mGround)
    }

    private func suggestionPanel(_ suggestion: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb")
                .font(.system(size: 13))
                .foregroundStyle(Color.mTerracotta)
            Text(suggestion)
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.7))
                .lineLimit(4)
        }
        .padding(14)
        .background(Color.mTerracottaTint)
    }

    // MARK: - Right inspector

    private var rightInspector: some View {
        Group {
            if let item = focused {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        itemPreview(item)
                        metadataTable(item)
                        setDateSection
                        destinationSection
                    }
                    .padding(20)
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "hand.point.left")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Color.mText.opacity(0.2))
                    Text("Select an item to review")
                        .font(.mBody)
                        .foregroundStyle(Color.mText.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.mGround)
    }

    private func itemPreview(_ item: MediaItem) -> some View {
        AsyncThumbnail(url: item.url, size: CGSize(width: 300, height: 200))
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func metadataTable(_ item: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MSectionHeader(title: "Metadata")
                .padding(.bottom, 8)
            metaRow("File", item.filename)
            metaRow("Size", item.fileSize.formattedFileSize)
            metaRow("Type", item.mediaType.rawValue.capitalized)
            metaRow("Date source", item.dateSource.rawValue.capitalized)
            if let d = item.captureDate {
                metaRow("Date", d.formatted(date: .abbreviated, time: .shortened))
            } else {
                metaRow("Date", "—")
            }
            if let cam = item.cameraModel {
                metaRow("Camera", cam)
            }
            if item.hasMissingEXIF {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.mTerracotta)
                    Text("EXIF metadata missing or unreadable")
                        .font(.mCaption)
                        .foregroundStyle(Color.mTerracotta)
                }
                .padding(.top, 6)
            }
        }
        .padding(14)
        .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.5))
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.mCaption)
                .foregroundStyle(Color.mText)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var setDateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MSectionHeader(title: "Set date")
            DatePicker(
                "Capture date",
                selection: $proposedDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            .labelsHidden()
            .datePickerStyle(.compact)
            .tint(Color.mTerracotta)
        }
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MSectionHeader(title: "Move to folder")
            TextField("Folder name", text: $proposedFolderName)
                .textFieldStyle(.plain)
                .font(.mBody)
                .padding(10)
                .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 10))
            Text("Leave blank to let Memento choose based on the date.")
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.4))
        }
    }

    // MARK: - Helpers

    private func toggleSelect(_ item: MediaItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
        focusedItemID = item.id
        // Start from the item's own (guessed) date when it has one.
        if let d = item.captureDate { proposedDate = d }
    }

    private func applyToSelected() {
        guard let planVM = vm.planVM else { return }
        let targets = selectedIDs.isEmpty ? items : items.filter { selectedIDs.contains($0.id) }
        planVM.resolveReviewItems(targets, date: proposedDate, folderName: proposedFolderName)
        vm.needsReviewItems = planVM.plan.needsReviewItems
        selectedIDs.removeAll()
        focusedItemID = nil
        proposedFolderName = ""
    }

    private func countFor(_ tab: ReviewTab) -> Int {
        switch tab {
        case .noDate:
            return vm.needsReviewItems.filter { $0.captureDate == nil }.count
        case .ambiguous:
            return vm.needsReviewItems.filter { $0.captureDate != nil && $0.hasMissingEXIF }.count
        case .unreadable:
            return vm.needsReviewItems.filter { !$0.hasMissingEXIF && $0.captureDate == nil }.count
        }
    }

    private func buildSuggestion() -> String? {
        let count = items.count
        guard count > 0 else { return nil }
        switch tab {
        case .noDate:
            return "\(count) \(count == 1 ? "item has" : "items have") no capture date. Assign a date or folder to include them in the organized library."
        case .ambiguous:
            return "\(count) \(count == 1 ? "item was" : "items were") placed by filename or filesystem date — check whether the dates look right."
        case .unreadable:
            return "\(count) \(count == 1 ? "file" : "files") could not be read. They will be skipped unless you assign a destination manually."
        }
    }
}

// MARK: - Review thumbnail cell

struct ReviewThumbnailCell: View {
    let item: MediaItem
    let isSelected: Bool
    let isFocused: Bool
    let onTap: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let img = thumbnail {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .saturation(0.6)
                    } else {
                        Color.mSurface
                    }
                }
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isFocused ? Color.mTerracotta : (isSelected ? Color.mSage : Color.clear),
                            lineWidth: 2.5
                        )
                )

                // Selection badge
                ZStack {
                    Circle().fill(isSelected ? Color.mTerracotta : Color.white.opacity(0.6))
                        .frame(width: 18, height: 18)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(5)
            }
        }
        .buttonStyle(.plain)
        .task { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        guard thumbnail == nil else { return }
        if let hit = ThumbnailLoader.cached(item.url, maxPixel: 180) {
            thumbnail = hit
        } else {
            thumbnail = await ThumbnailLoader.load(url: item.url, maxPixel: 180)
        }
    }
}

// MARK: - Async thumbnail helper

struct AsyncThumbnail: View {
    let url: URL
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
            } else {
                Color.mSurface.overlay { ProgressView().controlSize(.small) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        image = await ThumbnailLoader.load(url: url, maxPixel: Int(max(size.width, size.height)))
    }
}
