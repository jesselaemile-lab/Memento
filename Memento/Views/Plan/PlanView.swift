import SwiftUI

struct PlanView: View {
    @Environment(AppViewModel.self) private var appVM

    var body: some View {
        if let planVM = appVM.planVM {
            PlanContentView(planVM: planVM, appVM: appVM)
        } else {
            VStack(spacing: 0) {
                MScreenHeader("Plan")
                EmptyState(icon: "checklist", title: "No plan ready",
                           message: "Complete a scan to see the proposed folder structure.")
            }
        }
    }
}

struct PlanContentView: View {
    @Bindable var planVM: PlanViewModel
    let appVM: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            topBar

            MDivider()

            // Split: tree + inspector
            HStack(spacing: 0) {
                // Left: tree
                folderTree
                    .frame(width: 320)

                MDivider().frame(width: 1)

                // Right: inspector
                if let folder = planVM.selectedFolder {
                    FolderInspector(folder: folder, planVM: planVM)
                } else {
                    inspectorPlaceholder
                }
            }

            MDivider()

            // Footer
            footer
        }
        .background(Color.mGround)
    }

    // MARK: - Top bar

    private var topBar: some View {
        MScreenHeader(
            "Plan",
            subtitle: "\(planVM.plan.totalItems) items · \(planVM.plan.proposedFolders.count) folders · \(planVM.plan.totalSize.formattedFileSize)"
        ) {
            // Placement mode picker
            MSegmentedPicker(selection: $planVM.plan.placementMode,
                             options: PlacementMode.allCases) { $0.rawValue }

            if planVM.plan.duplicateSets.count > 0 {
                MPillButton(
                    "\(planVM.plan.duplicateSets.count) duplicate sets",
                    icon: "doc.on.doc",
                    style: .secondary
                ) { appVM.selectedSection = .duplicates }
            }
        }
    }

    // MARK: - Folder tree

    private var folderTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(planVM.foldersByYear, id: \.year) { group in
                    yearDisclosure(year: group.year, folders: group.folders)
                }
            }
            .padding(.vertical, 8)
        }
        .background(Color.mGround)
    }

    private func yearDisclosure(year: Int, folders: [PlannedFolder]) -> some View {
        DisclosureGroup(
            isExpanded: Binding(
                get: { planVM.expandedYears.contains(year) },
                set: { expanded in
                    if expanded { planVM.expandedYears.insert(year) }
                    else        { planVM.expandedYears.remove(year) }
                }
            )
        ) {
            ForEach(folders) { folder in
                folderRow(folder: folder)
            }
        } label: {
            HStack {
                Text(String(year))
                    .font(.mLabelBold)
                    .foregroundStyle(Color.mText)
                Spacer()
                Text("\(folders.count) folders")
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .tint(Color.mTerracotta)
        .padding(.horizontal, 8)
    }

    private func folderRow(folder: PlannedFolder) -> some View {
        let isSelected = planVM.selectedFolderID == folder.id
        return Button {
            planVM.selectedFolderID = folder.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.white : Color.mTerracotta.opacity(0.8))
                // Folder name on top, its month underneath, so nesting is visible without
                // cramming the full path onto one line.
                VStack(alignment: .leading, spacing: 1) {
                    Text(PlanViewModel.leafName(folder.relativePath))
                        .font(.mBody)
                        .foregroundStyle(isSelected ? Color.white : Color.mText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let month = PlanViewModel.monthComponent(folder.relativePath) {
                        Text(month)
                            .font(.mCaption)
                            .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.mText.opacity(0.45))
                    }
                }
                .help(folder.relativePath)
                Spacer()
                Text("\(folder.itemCount)")
                    .font(.mCaption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.mText.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isSelected ? Color.mTerracotta : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }

    // MARK: - Inspector placeholder

    private var inspectorPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "sidebar.right")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.mText.opacity(0.2))
            Text("Select a folder to inspect")
                .font(.mBody)
                .foregroundStyle(Color.mText.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mGround)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            MPillButton("Back", icon: "chevron.left", style: .secondary) {
                appVM.selectedSection = .newRun
            }

            Spacer()

            Text("Est. \(planVM.estimatedDuration)")
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.5))

            MPillButton("Apply plan", icon: "arrow.right", style: .primary) {
                appVM.applyPlan()
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.mSurface)
    }
}

// MARK: - Folder inspector

struct FolderInspector: View {
    @Environment(AppViewModel.self) private var appVM
    let folder: PlannedFolder
    @Bindable var planVM: PlanViewModel

    @State private var isEditingName = false
    @State private var editedName = ""

    private let thumbColumns = [GridItem(.adaptive(minimum: 80, maximum: 100), spacing: 4)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Folder name
                nameSection

                if let event = folder.event {
                    // Evidence tags
                    evidenceTags(event: event)

                    // Date range & stats
                    statsRow(event: event)

                    // "Why together" explanation
                    whySection(event: event)
                }

                // Thumbnail preview
                thumbnailGrid

                // Conflicts
                if !folder.conflicts.isEmpty { conflictsSection }

                // Actions
                actionsSection
            }
            .padding(24)
        }
        .background(Color.mGround)
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MSectionHeader(title: "Folder name")
            if isEditingName {
                HStack {
                    TextField("Folder name", text: $editedName)
                        .textFieldStyle(.plain)
                        .font(.mSubheadSemi)
                        .foregroundStyle(Color.mText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 10))
                    MPillButton("Save", style: .primary) {
                        planVM.rename(folder: folder, to: editedName)
                        isEditingName = false
                    }
                    MPillButton("Cancel", style: .secondary) { isEditingName = false }
                }
            } else {
                HStack {
                    Text(folder.name)
                        .font(.mSubheadSemi)
                        .foregroundStyle(Color.mText)
                    Spacer()
                    Button {
                        editedName = folder.name
                        isEditingName = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(Color.mTerracotta)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(folder.relativePath)
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.4))
                .lineLimit(2)
        }
    }

    private func evidenceTags(event: MediaEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MSectionHeader(title: "Grouped because")
            HStack(spacing: 6) {
                ForEach(event.evidenceTags, id: \.rawValue) { tag in
                    MTag(tag.rawValue, color: .mTerracottaTint, textColor: .mTerracottaDeep)
                }
            }
        }
    }

    private func statsRow(event: MediaEvent) -> some View {
        HStack(spacing: 10) {
            MStatPill(value: "\(folder.itemCount)", label: "Items")
            MStatPill(value: folder.totalSize.formattedFileSize, label: "Size")
            if event.videoCount > 0 {
                MStatPill(value: "\(event.videoCount)", label: "Videos")
            }
        }
    }

    private func whySection(event: MediaEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MSectionHeader(title: "Why these are together")
            Text(buildExplanation(event: event))
                .font(.mBody)
                .foregroundStyle(Color.mText.opacity(0.7))
                .lineLimit(4)
        }
    }

    private func buildExplanation(event: MediaEvent) -> String {
        var parts: [String] = []
        let rules = appVM.rules
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"
        if Calendar.current.isDate(event.startDate, inSameDayAs: event.endDate) {
            parts.append("All taken on \(f.string(from: event.startDate)).")
        } else {
            parts.append("Taken \(f.string(from: event.startDate)) – \(f.string(from: event.endDate)), with no break longer than \(Int(rules.timeGapHours)) hours between photos.")
        }
        if event.evidenceTags.contains(.gpsRadius) {
            parts.append("No jump of more than \(Int(rules.locationGapKilometers)) km between consecutive photos.")
        }
        if event.evidenceTags.contains(.sourceFolderName) {
            parts.append("The source folder name matched a meaningful event name.")
        }
        if event.evidenceTags.contains(.holiday) {
            parts.append("The dates line up with a holiday.")
        }
        if parts.isEmpty { parts.append("These items share a close date range.") }
        return parts.joined(separator: " ")
    }

    private var thumbnailGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            MSectionHeader(title: "Items (\(folder.itemCount))")
            LazyVGrid(columns: thumbColumns, spacing: 4) {
                ForEach(folder.items.prefix(20)) { item in
                    ThumbnailCell(item: item)
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var conflictsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MSectionHeader(title: "Filename conflicts")
            ForEach(folder.conflicts, id: \.originalName) { conflict in
                HStack {
                    Text(conflict.originalName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.mText.opacity(0.6))
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(Color.mTerracotta)
                    Text(conflict.resolvedName)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color.mText)
                }
            }
        }
    }

    private var actionsSection: some View {
        VStack(spacing: 8) {
            MDivider()
            HStack(spacing: 8) {
                MPillButton("Merge into…", style: .secondary) {}
                MPillButton("Exclude", style: .ghost) {
                    planVM.exclude(folder: folder)
                }
            }
        }
    }
}
