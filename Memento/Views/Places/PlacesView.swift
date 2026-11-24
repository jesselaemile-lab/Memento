import SwiftUI
import MapKit
import CoreLocation

struct PlacesView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var model = PlacesViewModel()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var selectedID: UUID?

    private typealias LocationCluster = PlacesViewModel.LocationCluster

    private var clusters: [LocationCluster] { model.clusters }
    private var noLocationCount: Int { model.noLocationCount }

    var body: some View {
        VStack(spacing: 0) {
            MScreenHeader("Places", subtitle: clusters.isEmpty ? nil : "\(clusters.count) places")
            if clusters.isEmpty {
                EmptyState(
                    icon: "map",
                    title: "No location data",
                    message: "Photos with GPS coordinates will appear on the map after you apply a plan."
                )
            } else {
                HStack(spacing: 0) {
                    mapPane
                    Rectangle().fill(Color.mBorder).frame(width: 1)
                    listPane
                        .frame(width: 260)
                }
            }
        }
        .task(id: appVM.organizedFolders.count) {
            model.rebuildIfNeeded(from: appVM.organizedFolders)
        }
    }

    // MARK: - Map

    private var mapPane: some View {
        Map(position: $cameraPosition) {
            ForEach(clusters) { cluster in
                Annotation(cluster.name, coordinate: cluster.coordinate, anchor: .bottom) {
                    annotationDot(cluster)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
    }

    private func annotationDot(_ cluster: LocationCluster) -> some View {
        let diameter = min(20 + CGFloat(cluster.count) / 4, 52)
        return ZStack {
            Circle()
                .fill(selectedID == cluster.id ? Color.mSageDeep : Color.mTerracotta)
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
            Text(cluster.count < 1000 ? "\(cluster.count)" : "\(cluster.count / 1000)k")
                .font(.mCaptionSemi)
                .foregroundStyle(.white)
        }
        .onTapGesture {
            selectedID = cluster.id
            cameraPosition = .region(MKCoordinateRegion(
                center: cluster.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
            ))
        }
    }

    // MARK: - Sidebar list

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Places").font(.mHeadline).foregroundStyle(Color.mText)
                Spacer()
                Text("\(clusters.count)").font(.mLabel).foregroundStyle(Color.mText.opacity(0.4))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.mSurface)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.mBorder).frame(height: 1) }

            ScrollView {
                VStack(spacing: 0) {
                    if noLocationCount > 0 {
                        HStack {
                            Text("\(noLocationCount) items have no location")
                                .font(.mCaption)
                                .foregroundStyle(Color.mText.opacity(0.45))
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        MDivider().padding(.leading, 16)
                    }

                    ForEach(clusters) { cluster in
                        placeRow(cluster)
                        MDivider().padding(.leading, 16)
                    }
                }
            }
            .background(Color.mGround)
        }
    }

    private func placeRow(_ cluster: LocationCluster) -> some View {
        Button {
            selectedID = cluster.id
            cameraPosition = .region(MKCoordinateRegion(
                center: cluster.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
            ))
        } label: {
            HStack {
                Circle()
                    .fill(selectedID == cluster.id ? Color.mTerracotta : Color.mSurface)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cluster.name).font(.mBodySemi).foregroundStyle(Color.mText).lineLimit(1)
                    Text("\(cluster.count) items").font(.mCaption).foregroundStyle(Color.mText.opacity(0.5))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(selectedID == cluster.id ? Color.mTerracottaTint : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
