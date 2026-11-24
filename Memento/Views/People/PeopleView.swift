import SwiftUI

struct PeopleView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var editingClusterID: UUID?
    @State private var editingName: String = ""
    @State private var showSingles: Bool = false
    @State private var isBuildingPlan: Bool = false

    private var named:   [FaceCluster] { appVM.faceClusters.filter(\.isNamed) }
    private var unnamed: [FaceCluster] { appVM.faceClusters.filter { !$0.isNamed } }
    /// Unnamed people seen in only one photo are usually strangers — hidden by default.
    private var visibleUnnamed: [FaceCluster] { showSingles ? unnamed : unnamed.filter { $0.totalItemCount > 1 } }
    private var hiddenSinglesCount: Int { unnamed.count - unnamed.filter { $0.totalItemCount > 1 }.count }

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            MScreenHeader("People", subtitle: appVM.faceClusters.isEmpty ? nil
                : "\(named.count) named · \(unnamed.count) unnamed")
            if appVM.isAwaitingPeopleNames {
                namingBanner
            }
            if appVM.faceClusters.isEmpty {
                EmptyState(
                    icon: "person.2",
                    title: "No people detected",
                    message: "Run a scan with face detection enabled to find people here."
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        if !named.isEmpty {
                            clusterSection("Named", clusters: named)
                        }
                        if !visibleUnnamed.isEmpty {
                            clusterSection("Unnamed — \(visibleUnnamed.count) \(visibleUnnamed.count == 1 ? "person" : "people")", clusters: visibleUnnamed)
                        }
                        if hiddenSinglesCount > 0 {
                            Toggle("Show \(hiddenSinglesCount) \(hiddenSinglesCount == 1 ? "person" : "people") seen in only one photo", isOn: $showSingles)
                                .toggleStyle(.checkbox)
                                .font(.mLabel)
                                .foregroundStyle(Color.mText.opacity(0.6))
                        }
                    }
                    .padding(28)
                }
                .background(Color.mGround)
            }
        }
    }

    // MARK: - Naming step banner

    private var namingBanner: some View {
        @Bindable var vm = appVM
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Name the people you want folders for")
                    .font(.mSubheadSemi)
                    .foregroundStyle(Color.mText)
                Text("Give two clusters the same name to merge them. Photos go to the person with the largest face; the rest go to “\(PlanBuilder.noPersonFolder)”.")
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.55))
                    .lineLimit(4)
            }

            Spacer()

            Picker("Inside each person", selection: $vm.rules.peopleSubStructure) {
                ForEach(GroupingRules.PeopleSubStructure.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            MPillButton(isBuildingPlan ? "Building…" : "Continue to plan", icon: "arrow.right", style: .primary) {
                guard !isBuildingPlan else { return }
                isBuildingPlan = true
                Task {
                    await appVM.continueToPlanWithPeople()
                    isBuildingPlan = false
                }
            }
            .disabled(named.isEmpty || isBuildingPlan)
            .opacity(named.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color.mTerracottaTint)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mBorder).frame(height: 1) }
    }

    // MARK: - Grid

    private func clusterSection(_ title: String, clusters: [FaceCluster]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.mHeadline).foregroundStyle(Color.mText)
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(clusters) { cluster in
                    ClusterCell(
                        cluster: cluster,
                        isEditing: editingClusterID == cluster.id,
                        editingName: editingClusterID == cluster.id ? $editingName : .constant(""),
                        onTapName: {
                            editingClusterID = cluster.id
                            editingName = cluster.name ?? ""
                        },
                        onCommit: { name in
                            appVM.nameCluster(id: cluster.id, name: name)
                            editingClusterID = nil
                        },
                        onCancel: { editingClusterID = nil }
                    )
                    .contextMenu {
                        Button("Rename…") {
                            editingClusterID = cluster.id
                            editingName = cluster.name ?? ""
                        }
                        Button("Not a person / don’t organize", role: .destructive) {
                            appVM.hideCluster(id: cluster.id)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Cluster cell

private struct ClusterCell: View {
    let cluster: FaceCluster
    let isEditing: Bool
    @Binding var editingName: String
    let onTapName: () -> Void
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            // Circular face crop
            ZStack {
                Circle()
                    .fill(Color.mSurface)
                    .frame(width: 88, height: 88)

                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 88, height: 88)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.mText.opacity(0.25))
                }
            }
            .overlay(Circle().strokeBorder(Color.mSurface, lineWidth: 3))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .task(id: cluster.sampleItems.first?.id) { await loadThumbnail() }

            // Item count
            Text("\(cluster.totalItemCount) photo\(cluster.totalItemCount == 1 ? "" : "s")")
                .font(.mCaption)
                .foregroundStyle(Color.mText.opacity(0.5))

            // Name field or label
            if isEditing {
                TextField("Enter name", text: $editingName)
                    .textFieldStyle(.roundedBorder)
                    .font(.mBodySemi)
                    .onSubmit { onCommit(editingName) }
                    .onExitCommand { onCancel() }
            } else {
                Button(action: onTapName) {
                    HStack(spacing: 4) {
                        Text(cluster.name ?? "Name")
                            .font(.mBodySemi)
                            .foregroundStyle(cluster.isNamed ? Color.mText : Color.mTerracotta)
                        if !cluster.isNamed {
                            Image(systemName: "pencil").font(.system(size: 10))
                                .foregroundStyle(Color.mTerracotta)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Loads the first sample photo and crops it to this person's face in that photo.
    private func loadThumbnail() async {
        guard let item = cluster.sampleItems.first,
              let image = await ThumbnailLoader.load(url: item.url, maxPixel: 1024, allowQuickLook: false)
        else { return }
        let face = cluster.faces.filter { $0.itemID == item.id }.max { $0.area < $1.area }
        thumbnail = face.flatMap { Self.crop(image, to: $0.boundingBox) } ?? image
    }

    private static func crop(_ image: NSImage, to box: CGRect) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // Vision boxes have a lower-left origin; pad generously so the crop shows the whole head.
        let rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
            .insetBy(dx: -box.width * w * 0.4, dy: -box.height * h * 0.4)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard let cropped = cg.cropping(to: rect.integral) else { return nil }
        return NSImage(cgImage: cropped, size: .zero)
    }
}
