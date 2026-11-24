import SwiftUI
import ImageIO

struct TimelineView: View {
    @Environment(AppViewModel.self) private var vm

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            MScreenHeader("Timeline", subtitle: vm.organizedFolders.isEmpty ? nil
                : "\(vm.organizedFolders.count) folders · \(vm.organizedFolders.reduce(0) { $0 + $1.itemCount }) items")
            timelineContent
        }
    }

    @ViewBuilder
    private var timelineContent: some View {
        if vm.organizedFolders.isEmpty {
            EmptyState(
                icon: "photo.on.rectangle.angled",
                title: "Your library is empty",
                message: "Run Memento on a folder or drive to organize your photos and videos into events.",
                action: { vm.selectedSection = .newRun },
                actionLabel: "Start organizing"
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32, pinnedViews: [.sectionHeaders]) {
                    ForEach(groupedByYear, id: \.year) { yearGroup in
                        Section {
                            ForEach(yearGroup.folders) { folder in
                                eventSection(folder: folder)
                            }
                        } header: {
                            yearHeader(year: yearGroup.year)
                        }
                    }
                }
                .padding(24)
            }
            .background(Color.mGround)
        }
    }

    // MARK: - Year header

    private func yearHeader(year: Int) -> some View {
        HStack {
            Text(String(year))
                .font(.mLargeTitle)
                .foregroundStyle(Color.mText)
            Spacer()
        }
        .padding(.vertical, 8)
        .background(Color.mGround)
    }

    // MARK: - Event section

    private func eventSection(folder: PlannedFolder) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Event header
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.mSubheadSemi)
                        .foregroundStyle(Color.mText)
                    HStack(spacing: 8) {
                        if let event = folder.event {
                            Text(eventDateRange(event))
                                .font(.mCaption)
                                .foregroundStyle(Color.mText.opacity(0.55))
                            if let place = event.locationName {
                                Text("·").foregroundStyle(Color.mText.opacity(0.3))
                                Text(place)
                                    .font(.mCaption)
                                    .foregroundStyle(Color.mText.opacity(0.55))
                            }
                        }
                        Text("·").foregroundStyle(Color.mText.opacity(0.3))
                        Text("\(folder.itemCount) items")
                            .font(.mCaption)
                            .foregroundStyle(Color.mText.opacity(0.55))
                    }
                }
                Spacer()
            }

            // Thumbnail grid
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(folder.items.prefix(60)) { item in
                    ThumbnailCell(item: item)
                }
                if folder.itemCount > 60 {
                    overflowCell(count: folder.itemCount - 60)
                }
            }
        }
    }

    private func overflowCell(count: Int) -> some View {
        ZStack {
            Color.mSurface
            Text("+\(count)")
                .font(.mHeadline)
                .foregroundStyle(Color.mText.opacity(0.6))
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - Helpers

    private var groupedByYear: [(year: Int, folders: [PlannedFolder])] {
        let dict = Dictionary(grouping: vm.organizedFolders) {
            ($0.event?.year) ?? 0
        }
        return dict.keys.sorted(by: >).map { (year: $0, folders: dict[$0]!.sorted {
            ($0.event?.startDate ?? .distantPast) > ($1.event?.startDate ?? .distantPast)
        }) }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()

    private func eventDateRange(_ event: MediaEvent) -> String {
        let fmt = Self.dateFormatter
        let cal = Calendar.current
        if cal.isDate(event.startDate, inSameDayAs: event.endDate) {
            return fmt.string(from: event.startDate)
        }
        if cal.component(.year, from: event.startDate) != cal.component(.year, from: event.endDate) {
            let y = DateFormatter(); y.dateFormat = "MMM d, yyyy"
            return "\(y.string(from: event.startDate)) – \(y.string(from: event.endDate))"
        }
        if cal.component(.month, from: event.startDate) == cal.component(.month, from: event.endDate) {
            return "\(fmt.string(from: event.startDate))–\(cal.component(.day, from: event.endDate))"
        }
        return "\(fmt.string(from: event.startDate)) – \(fmt.string(from: event.endDate))"
    }
}

// MARK: - Thumbnail cell

struct ThumbnailCell: View {
    let item: MediaItem
    @State private var thumbnail: NSImage?

    var body: some View {
        // The square sets the cell's size; the photo fills it as an overlay and is clipped,
        // so wide or tall images can never spill into neighbouring cells.
        Color.mSurface
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .saturation(0.6)
                        .contrast(0.85)
                        .brightness(0.05)
                } else {
                    Image(systemName: item.mediaType == .video ? "video" : "photo")
                        .foregroundStyle(Color.mText.opacity(0.3))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .overlay(alignment: .bottomTrailing) { videoBadge }
            .task(id: item.id) {
                if let hit = ThumbnailLoader.cached(item.url, maxPixel: 300) {
                    thumbnail = hit
                } else {
                    thumbnail = await ThumbnailLoader.load(url: item.url, maxPixel: 300)
                }
            }
    }

    @ViewBuilder
    private var videoBadge: some View {
        if item.mediaType == .video, let dur = item.durationSeconds {
            Text(formatDuration(dur))
                .font(.mCaptionSemi)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s < 3600
            ? String(format: "%d:%02d", s / 60, s % 60)
            : String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
