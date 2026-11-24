import SwiftUI

@main
struct MementoApp: App {
    var body: some Scene {
        WindowGroup {
            AppShell()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}
