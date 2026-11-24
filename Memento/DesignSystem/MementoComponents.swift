import SwiftUI

// MARK: - Pill Button

struct MPillButton: View {
    let label: String
    let icon: String?
    let style: Style
    let action: () -> Void

    enum Style { case primary, secondary, ghost, destructive }

    init(_ label: String, icon: String? = nil, style: Style = .primary, action: @escaping () -> Void) {
        self.label = label; self.icon = icon; self.style = style; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(label).font(.mBodySemi)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(fgColor)
            .background(bgColor, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var fgColor: Color {
        switch style {
        case .primary:     .white
        case .secondary:   .mText
        case .ghost:       .mTerracotta
        case .destructive: .white
        }
    }
    private var bgColor: Color {
        switch style {
        case .primary:     .mTerracotta
        case .secondary:   .mSurface
        case .ghost:       .clear
        case .destructive: Color(hex: "c0392b")
        }
    }
}

// MARK: - Card

struct MCard<Content: View>: View {
    var padding: CGFloat
    let content: Content

    init(padding: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

// MARK: - Tag

struct MTag: View {
    let label: String
    var color: Color = .mTerracottaTint
    var textColor: Color = .mTerracottaDeep

    init(_ label: String, color: Color = .mTerracottaTint, textColor: Color = .mTerracottaDeep) {
        self.label = label; self.color = color; self.textColor = textColor
    }

    var body: some View {
        Text(label)
            .font(.mCaptionSemi)
            .foregroundStyle(textColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
    }
}

// MARK: - Section Header

struct MSectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.mCaptionSemi)
            .foregroundStyle(Color.mText.opacity(0.45))
            .tracking(1.2)
    }
}

// MARK: - Segmented Picker

/// Themed replacement for `.pickerStyle(.segmented)`, whose system accent (blue) and
/// white unselected labels don't fit the warm palette.
struct MSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    init(selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self._selection = selection; self.options = options; self.label = label
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(isSelected ? .mLabelBold : .mLabel)
                        .foregroundStyle(isSelected ? Color.mGround : Color.mText.opacity(0.7))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            isSelected ? Color.mTerracotta : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.mText.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.mBorder, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Screen Header

/// The title bar every screen shows at the top: title, optional subtitle, optional
/// trailing controls. Keeps screens consistent whether or not they have content.
struct MScreenHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, subtitle: String? = nil, icon: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self.subtitle = subtitle; self.icon = icon; self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.mTerracotta)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.mTitle).foregroundStyle(Color.mText)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.mCaption)
                        .foregroundStyle(Color.mText.opacity(0.55))
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color.mSurface)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mBorder).frame(height: 1) }
    }
}

extension MScreenHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, icon: String? = nil) {
        self.init(title, subtitle: subtitle, icon: icon) { EmptyView() }
    }
}

// MARK: - Stat Pill

struct MStatPill: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.mHeadline).foregroundStyle(Color.mText)
            Text(label).font(.mCaption).foregroundStyle(Color.mText.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.mSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Progress Bar

struct MProgressBar: View {
    let value: Double
    var color: Color = .mTerracotta
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.mText.opacity(0.08)).frame(height: 6)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * max(0, min(1, value)), height: 6)
                    .animation(.easeInOut(duration: 0.25), value: value)
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Divider

struct MDivider: View {
    var body: some View {
        Rectangle().fill(Color.mText.opacity(0.08)).frame(height: 1)
    }
}

// MARK: - File size formatting

extension Int64 {
    nonisolated var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

extension Double {
    var formattedThroughput: String {
        let mbps = self / 1_000_000
        if mbps >= 1 { return String(format: "%.1f MB/s", mbps) }
        let kbps = self / 1_000
        return String(format: "%.0f KB/s", kbps)
    }
}
