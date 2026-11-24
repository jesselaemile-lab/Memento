import SwiftUI

struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var action: (() -> Void)? = nil
    var actionLabel: String = "Get started"

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.mTerracotta.opacity(0.7))

            VStack(spacing: 8) {
                Text(title)
                    .font(.mTitle)
                    .foregroundStyle(Color.mText)
                Text(message)
                    .font(.mBody)
                    .foregroundStyle(Color.mText.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }

            if let action {
                MPillButton(actionLabel, icon: "plus", action: action)
                    .padding(.top, 4)
            }
        }
        .padding(60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mGround)
    }
}

struct ComingSoonView: View {
    let section: SidebarSection
    var body: some View {
        EmptyState(
            icon: section.systemIcon,
            title: section.displayName,
            message: "This section is coming in a future update."
        )
    }
}
