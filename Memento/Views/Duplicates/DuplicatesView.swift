import SwiftUI

struct DuplicatesView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var selectedKind: DuplicateKind? = nil
    @State private var keeperRule: PlanViewModel.KeeperRule = .highestRes

    private var sets: [DuplicateSet] { vm.currentDuplicateSets }

    private var displayed: [DuplicateSet] {
        guard let kind = selectedKind else { return sets }
        return sets.filter { $0.kind == kind }
    }

    private var totalSaved: Int64 { sets.reduce(0) { $0 + $1.spaceSaved } }

    var body: some View {
        VStack(spacing: 0) {
            MScreenHeader("Duplicates", subtitle: sets.isEmpty ? nil
                : "\(sets.count) sets · frees \(totalSaved.formattedFileSize)")
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if sets.isEmpty {
            if let last = vm.runHistory.first, last.status == .completed, last.duplicatesQuarantined > 0 {
                // After a run the decisions are done — point to where the extra copies went.
                EmptyState(
                    icon: "archivebox",
                    title: "\(last.duplicatesQuarantined) duplicate\(last.duplicatesQuarantined == 1 ? "" : "s") moved to Quarantine",
                    message: "Your last run kept one copy of each photo and moved the extras to the “_Duplicates (quarantine)” folder. Nothing was deleted — review or trash them from Quarantine.",
                    action: { vm.selectedSection = .quarantine },
                    actionLabel: "Open Quarantine"
                )
            } else {
                EmptyState(
                    icon: "doc.on.doc",
                    title: "No duplicates to review",
                    message: "Start a new run. Any duplicates it finds show up here so you can pick which copy to keep before anything is moved."
                )
            }
        } else {
            VStack(spacing: 0) {
                explainer
                toolbar
                MDivider()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(displayed) { set in
                            DuplicateSetCard(set: set) { keeperID in
                                vm.planVM?.setKeeperRule(for: set, keeperID: keeperID)
                            }
                        }
                    }
                    .padding(24)
                }
                .background(Color.mGround)
            }
        }
    }

    // MARK: - Explainer

    private var explainer: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.mTerracotta)
            Text("Each group below is the same photo more than once. **Click the photo you want to keep.** When you apply the plan, that one is organized and the others move to the quarantine folder — nothing is deleted.")
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.75))
                // A bounded line limit, not fixedSize(vertical:): inside NavigationSplitView
                // fixedSize text is measured at a tiny width and pushes the window off-screen.
                .lineLimit(3)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mTerracottaTint)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        // Plain HStack, not a horizontal ScrollView: inside NavigationSplitView a horizontal
        // scroll view grows vertically without bound and pushes the whole window out of view.
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                filterPill(label: "All (\(sets.count))", kind: nil)
                ForEach(DuplicateKind.allCases, id: \.self) { kind in
                    let count = sets.filter { $0.kind == kind }.count
                    if count > 0 { filterPill(label: "\(kind.rawValue) (\(count))", kind: kind) }
                }
            }
            .fixedSize()
            Spacer(minLength: 12)
            Text("Pick for all:").font(.mLabel).foregroundStyle(Color.mText.opacity(0.6))
            MSegmentedPicker(selection: $keeperRule, options: PlanViewModel.KeeperRule.allCases) { $0.rawValue }
                .onChange(of: keeperRule) { _, rule in vm.planVM?.applyKeeperRule(rule) }
                .disabled(vm.planVM == nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Color.mSurface)
        .onAppear {
            if let applied = vm.planVM?.appliedKeeperRule {
                keeperRule = applied          // reflect the earlier choice, keep manual picks
            } else {
                vm.planVM?.applyKeeperRule(keeperRule)
            }
        }
    }

    private func filterPill(label: String, kind: DuplicateKind?) -> some View {
        let isSelected = selectedKind == kind
        return Button { selectedKind = kind } label: {
            Text(label)
                .font(.mCaptionSemi)
                .foregroundStyle(isSelected ? Color.mGround : Color.mText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.mTerracotta : Color.mGround, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Duplicate set card

struct DuplicateSetCard: View {
    let set: DuplicateSet
    let onChooseKeeper: (UUID) -> Void

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 14)]

    var body: some View {
        MCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    MTag(set.kind.rawValue, color: .mTerracottaTint, textColor: .mTerracottaDeep)
                    Text(set.kind.quarantinesCopies
                         ? "\(set.items.count) copies — keeping 1"
                         : "Related shots — all are kept")
                        .font(.mCaption)
                        .foregroundStyle(Color.mText.opacity(0.55))
                    Spacer()
                    if set.spaceSaved > 0 {
                        Text("Frees \(set.spaceSaved.formattedFileSize)")
                            .font(.mCaption)
                            .foregroundStyle(Color.mSageDeep)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.mSageTint, in: Capsule())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                MDivider()

                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(set.items) { item in
                        DuplicateChoice(
                            item: item,
                            isKeeper: item.id == set.keeperID || !set.kind.quarantinesCopies,
                            isChoosable: set.kind.quarantinesCopies,
                            isBest: isHighestResolution(item)
                        ) { onChooseKeeper(item.id) }
                    }
                }
                .padding(16)
            }
        }
    }

    private func isHighestResolution(_ item: MediaItem) -> Bool {
        let px = { (i: MediaItem) in i.dimensions.map { $0.width * $0.height } ?? 0 }
        let best = set.items.map(px).max() ?? 0
        return best > 0 && px(item) == best && set.items.filter { px($0) == best }.count < set.items.count
    }
}

// MARK: - One photo in a set

private struct DuplicateChoice: View {
    let item: MediaItem
    let isKeeper: Bool
    let isChoosable: Bool
    let isBest: Bool
    let onChoose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onChoose) {
            VStack(alignment: .leading, spacing: 8) {
                ThumbnailCell(item: item)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isKeeper ? Color.mSage : Color.clear, lineWidth: 3)
                    )
                    .opacity(isKeeper ? 1 : 0.55)
                    .overlay(alignment: .topLeading) { statusBadge.padding(8) }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename)
                        .font(.mCaptionSemi)
                        .foregroundStyle(Color.mText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        if let d = item.dimensions {
                            Text("\(Int(d.width)) × \(Int(d.height))")
                        }
                        Text(item.fileSize.formattedFileSize)
                        if isBest { Text("· highest res").foregroundStyle(Color.mSageDeep) }
                    }
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.55))
                    Text(item.url.deletingLastPathComponent().lastPathComponent)
                        .font(.mCaption)
                        .foregroundStyle(Color.mText.opacity(0.4))
                        .lineLimit(1)
                }

                if isChoosable {
                    Text(isKeeper ? "Keeping this one" : "Keep this one instead")
                        .font(.mLabelBold)
                        .foregroundStyle(isKeeper ? Color.mGround : Color.mTerracottaDeep)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(isKeeper ? Color.mSage : (isHovering ? Color.mTerracottaTint : Color.mGround),
                                    in: Capsule())
                        .overlay(Capsule().strokeBorder(isKeeper ? Color.clear : Color.mTerracotta.opacity(0.5), lineWidth: 1))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isChoosable || isKeeper)
        .onHover { isHovering = $0 }
        .help(isChoosable ? (isKeeper ? "This copy will be organized" : "Click to keep this copy instead") : "")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isKeeper {
            Label(isChoosable ? "Keep" : "Kept", systemImage: "checkmark.circle.fill")
                .font(.mCaptionSemi)
                .foregroundStyle(Color.mGround)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.mSage, in: Capsule())
        } else {
            Label("To quarantine", systemImage: "archivebox")
                .font(.mCaptionSemi)
                .foregroundStyle(Color.mGround)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.mText.opacity(0.55), in: Capsule())
        }
    }
}
