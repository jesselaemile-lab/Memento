import SwiftUI
import AppKit

struct HistoryView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var expandedRunID: UUID?
    @State private var revertingRunID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            historyHeader
            if appVM.runHistory.isEmpty {
                EmptyState(
                    icon: "clock.arrow.circlepath",
                    title: "No run history",
                    message: "Completed runs will appear here after you apply a plan."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(appVM.runHistory) { record in
                            RunCard(
                                record: record,
                                isExpanded: expandedRunID == record.id,
                                isReverting: revertingRunID == record.id
                            ) { expandedRunID = expandedRunID == record.id ? nil : record.id }
                            onRevert: {
                                Task {
                                    revertingRunID = record.id
                                    await appVM.revertRun(record: record)
                                    revertingRunID = nil
                                }
                            }
                            onRevertToCheckpoint: { token in
                                Task { await appVM.revertToCheckpoint(token: token, in: record) }
                            }
                            onCopyCSV: {
                                Task {
                                    let csv = await appVM.journalCSV(for: record)
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(csv, forType: .string)
                                }
                            }
                        }
                    }
                    .padding(20)
                }
                .background(Color.mGround)
            }
        }
        .background(Color.mGround)
        .alert(
            "Revert",
            isPresented: Binding(
                get: { appVM.revertMessage != nil },
                set: { if !$0 { appVM.revertMessage = nil } }
            )
        ) {
            Button("OK") { appVM.revertMessage = nil }
        } message: {
            Text(appVM.revertMessage ?? "")
        }
    }

    private var historyHeader: some View {
        MScreenHeader("History", subtitle: appVM.runHistory.isEmpty ? nil
            : "\(appVM.runHistory.count) run\(appVM.runHistory.count == 1 ? "" : "s")")
    }
}

// MARK: - RunCard

struct RunCard: View {
    let record: RunRecord
    let isExpanded: Bool
    let isReverting: Bool
    let onToggle: () -> Void
    let onRevert: () -> Void
    let onRevertToCheckpoint: (String) -> Void
    let onCopyCSV: () -> Void

    @State private var showRevertConfirm = false
    @State private var csvCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            if isExpanded {
                MDivider().padding(.horizontal, 16)
                expandedDetail
            }
        }
        .background(Color.mSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.mBorder, lineWidth: 1))
        .confirmationDialog("Revert this entire run?", isPresented: $showRevertConfirm, titleVisibility: .visible) {
            Button("Revert", role: .destructive) { onRevert() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Files will be moved back to their original locations. This cannot be undone from Memento.")
        }
    }

    // MARK: Card header

    private var cardHeader: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    RunStatusBadge(status: record.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.sourcePaths.first ?? "Unknown source")
                            .font(.mBodySemi)
                            .foregroundStyle(Color.mText)
                            .lineLimit(1)
                        Text(record.startDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.mCaption)
                            .foregroundStyle(Color.mText.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.mText.opacity(0.4))
                }
                HStack(spacing: 8) {
                    countChip("\(record.itemsMoved) moved")
                    countChip("\(record.itemsCopied) copied")
                    countChip("0 deleted", dimColor: false, accent: .mSage)
                    if record.duplicatesQuarantined > 0 {
                        countChip("\(record.duplicatesQuarantined) quarantined")
                    }
                }
            }
            .padding(16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func countChip(_ text: String, dimColor: Bool = true, accent: Color? = nil) -> some View {
        Text(text)
            .font(.mCaption)
            .foregroundStyle(accent ?? Color.mText.opacity(dimColor ? 0.55 : 0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.mText.opacity(0.06))
            .clipShape(Capsule())
    }

    // MARK: Expanded detail

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !record.checkpoints.isEmpty {
                checkpointList
                MDivider().padding(.horizontal, 16)
            }
            cardFooter
        }
    }

    private var checkpointList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Checkpoints")
                .font(.mLabel)
                .foregroundStyle(Color.mText.opacity(0.55))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(Array(record.checkpoints.reversed())) { cp in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cp.token).font(.mBodySemi).foregroundStyle(Color.mText)
                        Text("\(cp.itemsCompleted) items · \(cp.bytesCompleted.formattedFileSize)")
                            .font(.mCaption)
                            .foregroundStyle(Color.mText.opacity(0.55))
                    }
                    Spacer()
                    MPillButton("Revert to here", icon: "arrow.uturn.backward", style: .secondary) {
                        onRevertToCheckpoint(cp.token)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    if cp.id != record.checkpoints.first?.id {
                        Rectangle().fill(Color.mBorder).frame(height: 1)
                            .padding(.leading, 16)
                    }
                }
            }
        }
    }

    private var cardFooter: some View {
        HStack(spacing: 10) {
            if isReverting {
                ProgressView().controlSize(.small)
                Text("Reverting…").font(.mCaption).foregroundStyle(Color.mText.opacity(0.6))
            } else if record.status == .reverted {
                Label("Reverted", systemImage: "checkmark.circle")
                    .font(.mCaption)
                    .foregroundStyle(Color.mSage)
            } else {
                MPillButton("Revert entire run", icon: "arrow.uturn.backward", style: .secondary) {
                    showRevertConfirm = true
                }
            }
            Spacer()
            MPillButton(csvCopied ? "Copied" : "Copy CSV", icon: "doc.on.doc", style: .secondary) {
                onCopyCSV()
                csvCopied = true
                Task { try? await Task.sleep(nanoseconds: 2_000_000_000); csvCopied = false }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Status badge

struct RunStatusBadge: View {
    let status: RunRecord.RunStatus

    var body: some View {
        Text(status.rawValue)
            .font(.mCaptionSemi)
            .foregroundStyle(fgColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bgColor)
            .clipShape(Capsule())
    }

    private var fgColor: Color {
        switch status {
        case .completed:   .mSageDeep
        case .interrupted: .mTerracottaDeep
        case .reverted:    Color.mText.opacity(0.6)
        case .inProgress:  Color.mText
        }
    }

    private var bgColor: Color {
        switch status {
        case .completed:   .mSageTint
        case .interrupted: .mTerracottaTint
        case .reverted:    Color.mText.opacity(0.06)
        case .inProgress:  Color.mText.opacity(0.06)
        }
    }
}
