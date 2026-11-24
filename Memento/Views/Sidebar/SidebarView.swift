import SwiftUI

struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        // Plain buttons instead of List(selection:) so macOS doesn't draw its blue
        // selection highlight behind the terracotta pill.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sidebarSection("Library") {
                    sidebarRow(.timeline)
                    sidebarRow(.folders)
                    sidebarRow(.people)
                    sidebarRow(.places)
                }

                sidebarSection("Needs you") {
                    if vm.interruptedRun != nil { sidebarRow(.interrupted) }
                    sidebarRow(.needsReview, badge: vm.needsReviewItems.count)
                    sidebarRow(.duplicates, badge: vm.duplicateSets.count)
                    sidebarRow(.quarantine, badge: vm.quarantineCount)
                }

                sidebarSection("Runs") {
                    sidebarRow(.newRun)
                    if vm.scanVM != nil || vm.isExecuting {
                        sidebarRow(.scanning)
                    }
                    if vm.planVM != nil {
                        sidebarRow(.plan)
                    }
                    sidebarRow(.history)
                    sidebarRow(.rules)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        // A shade darker than the content area so the two panes read as separate regions,
        // with a visible rule on the trailing edge (the screen headers share this colour).
        .background(Color.mSurface.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.mText.opacity(0.18)).frame(width: 1).ignoresSafeArea()
        }
    }

    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            MSectionHeader(title: title)
                .padding(.leading, 12)
                .padding(.bottom, 4)
            rows()
        }
    }

    private func sidebarRow(_ section: SidebarSection, badge: Int = 0) -> some View {
        let isSelected = vm.selectedSection == section
        return Button {
            vm.selectedSection = section
        } label: {
            sidebarRowLabel(section, badge: badge, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar.\(section.rawValue)")
    }

    private func sidebarRowLabel(_ section: SidebarSection, badge: Int, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemIcon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.mTerracotta)
                .frame(width: 20)

            Text(section.displayName)
                .font(.mBody)
                .foregroundStyle(isSelected ? Color.white : Color.mText)

            Spacer()

            if badge > 0 {
                Text("\(badge)")
                    .font(.mCaptionSemi)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.mTerracottaDeep)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        isSelected
                            ? Color.white.opacity(0.25)
                            : Color.mTerracottaTint,
                        in: Capsule()
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.mTerracotta : Color.clear,
            in: RoundedRectangle(cornerRadius: 999, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
    }
}
