import SwiftUI

struct FoldersView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var model = FoldersViewModel()
    @State private var selectedID: UUID?

    typealias SortField = FoldersViewModel.SortField

    private var sortedFolders: [PlannedFolder] { model.sortedFolders }

    var body: some View {
        VStack(spacing: 0) {
            MScreenHeader("Folders", subtitle: appVM.organizedFolders.isEmpty ? nil
                : "\(appVM.organizedFolders.count) folders · \(totalItemCount) items · \(totalSize.formattedFileSize)")
            if appVM.organizedFolders.isEmpty {
                EmptyState(
                    icon: "folder",
                    title: "No organized folders",
                    message: "Apply a plan to see the resulting folder structure here."
                )
            } else {
                VStack(spacing: 0) {
                    columnBar
                    Rectangle().fill(Color.mBorder).frame(height: 1)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(sortedFolders) { folder in
                                folderRow(folder)
                                Rectangle().fill(Color.mBorder).frame(height: 1)
                                    .padding(.leading, 20)
                            }
                        }
                    }
                    .background(Color.mGround)
                }
                .background(Color.mGround)
            }
        }
        .task(id: appVM.organizedFolders.count) {
            model.rebuildIfNeeded(from: appVM.organizedFolders)
        }
    }

    // MARK: - Header

    private var totalItemCount: Int { model.totalItemCount }
    private var totalSize: Int64    { model.totalSize }

    // MARK: - Column bar

    private var columnBar: some View {
        HStack(spacing: 0) {
            sortableColumn("Folder",    field: .name,  flex: true)
            sortableColumn("Items",     field: .items, width: 70)
            sortableColumn("Size",      field: .size,  width: 90)
            sortableColumn("Date range",field: .date,  width: 200)
        }
        .padding(.horizontal, 20)
        .frame(height: 34)
        .background(Color.mSurface)
    }

    private func sortableColumn(_ label: String, field: SortField, flex: Bool = false, width: CGFloat = 0) -> some View {
        Button {
            model.toggleSort(field, folders: appVM.organizedFolders)
        } label: {
            HStack(spacing: 4) {
                Text(label).font(.mLabel).foregroundStyle(Color.mText.opacity(0.55))
                if model.sortField == field {
                    Image(systemName: model.sortAscending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.mTerracotta)
                }
                if flex { Spacer() }
            }
            .frame(width: flex ? nil : width, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Row

    private func folderRow(_ folder: PlannedFolder) -> some View {
        HStack(spacing: 0) {
            // Name + path
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.mBodySemi)
                    .foregroundStyle(Color.mText)
                    .lineLimit(1)
                Text(folder.relativePath)
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.4))
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Text("\(folder.itemCount)")
                .font(.mBody)
                .foregroundStyle(Color.mText)
                .frame(width: 70, alignment: .trailing)

            Text(folder.totalSize.formattedFileSize)
                .font(.mBody)
                .foregroundStyle(Color.mText)
                .frame(width: 90, alignment: .trailing)

            Group {
                if let event = folder.event {
                    Text(dateRangeString(event))
                        .font(.mCaption)
                        .foregroundStyle(Color.mText.opacity(0.6))
                } else {
                    Text("—").font(.mCaption).foregroundStyle(Color.mText.opacity(0.3))
                }
            }
            .frame(width: 200, alignment: .leading)
            .padding(.leading, 12)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .background(selectedID == folder.id ? Color.mTerracottaTint : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = folder.id }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy"; return f
    }()

    private func dateRangeString(_ event: MediaEvent) -> String {
        let fmt = Self.dateFormatter
        let a = fmt.string(from: event.startDate)
        let b = fmt.string(from: event.endDate)
        return a == b ? a : "\(a) – \(b)"
    }
}
