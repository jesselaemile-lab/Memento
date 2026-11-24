import SwiftUI

struct AppShell: View {
    @State private var appVM = AppViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if appVM.showsProgressBanner {
                    ProgressBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                contentView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Hairline plus a soft inner shadow on the content's leading edge so the
            // sidebar sits visibly beside (not blended into) the main area.
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Rectangle().fill(Color.mText.opacity(0.18)).frame(width: 1)
                    LinearGradient(
                        colors: [Color.black.opacity(0.07), Color.clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 10)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.2), value: appVM.showsProgressBanner)
        }
        .environment(appVM)
        .frame(minWidth: 1320, minHeight: 880)
        .background(Color.mGround)
        .overlay(alignment: .bottomTrailing) {
            if UITestSupport.isActive { UITestStatusLabel() }
        }
        .onAppear {
            MementoFont.register()
            // Must run before setup() so the run store and library open in the test directory.
            if UITestSupport.isActive { UITestSupport.prepare() }
            appVM.setup()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch appVM.selectedSection {
        case .timeline:    TimelineView()
        case .newRun:      SourceView()
        case .scanning:    ScanView()
        case .plan:        PlanView()
        case .duplicates:  DuplicatesView()
        case .needsReview: NeedsReviewView()
        case .history:     HistoryView()
        case .interrupted: RecoveryView()
        case .folders:     FoldersView()
        case .people:      PeopleView()
        case .places:      PlacesView()
        case .quarantine:  QuarantineView()
        case .rules:       RulesView()
        }
    }
}
