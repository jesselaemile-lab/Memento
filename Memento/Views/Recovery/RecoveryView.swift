import SwiftUI

struct RecoveryView: View {
    @Environment(AppViewModel.self) private var appVM
    @State private var vm = RecoveryViewModel()
    @State private var showRevertConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            recoveryHeader
            if let summary = vm.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        sourceSection(summary)
                        if summary.isSourceVolumeMissing { missingVolumePanel(summary.sourceDescription) }
                        journalTable(summary)
                        if summary.copiedUnverified > 0 { verifySection(summary) }
                        MDivider()
                        actionRow(summary)
                    }
                    .padding(28)
                }
                .background(Color.mGround)
            } else if appVM.interruptedRun != nil {
                VStack { ProgressView("Analyzing journal…").padding(40) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mGround)
            } else {
                EmptyState(
                    icon: "exclamationmark.triangle",
                    title: "No interrupted run",
                    message: "Previous runs completed without interruption."
                )
            }
        }
        .background(Color.mGround)
        .task {
            if let record = appVM.interruptedRun { await vm.prepare(record: record) }
        }
    }

    // MARK: - Header

    private var recoveryHeader: some View {
        let d = appVM.interruptedRun.map { $0.endDate ?? $0.startDate }
        return MScreenHeader(
            "Run interrupted",
            subtitle: d.map { "Interrupted \($0.formatted(date: .abbreviated, time: .shortened))" },
            icon: "exclamationmark.triangle.fill"
        )
    }

    // MARK: - Source

    private func sourceSection(_ s: RecoverySummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source").font(.mLabel).foregroundStyle(Color.mText.opacity(0.55))
            Text(s.sourceDescription.isEmpty ? "Unknown" : s.sourceDescription)
                .font(.mBody)
                .foregroundStyle(Color.mText)
                .lineLimit(2)
        }
    }

    private func missingVolumePanel(_ path: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 20))
                .foregroundStyle(Color.mTerracotta)
            VStack(alignment: .leading, spacing: 2) {
                Text("Source volume not found")
                    .font(.mBodySemi)
                    .foregroundStyle(Color.mText)
                Text(path.isEmpty ? "Volume was disconnected." : path)
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.6))
            }
        }
        .padding(16)
        .background(Color.mTerracottaTint)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mTerracotta.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Journal table

    private func journalTable(_ s: RecoverySummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Journal summary")
                .font(.mLabel)
                .foregroundStyle(Color.mText.opacity(0.55))
            VStack(spacing: 0) {
                tableRow("Confirmed moved & checksummed",  value: s.confirmedMoved,  icon: "checkmark.circle.fill", iconColor: .mSage)
                MDivider()
                tableRow("Moved after last checkpoint",    value: s.copiedUnverified, icon: "questionmark.circle.fill", iconColor: .mTerracotta)
                MDivider()
                tableRow("Failed transfers",               value: s.failed,           icon: "xmark.circle.fill", iconColor: s.failed > 0 ? Color(hex: "c0392b") : Color.mText.opacity(0.3))
                MDivider()
                tableRow("Quarantined (duplicates)",       value: s.quarantined,      icon: "archivebox.fill", iconColor: Color.mText.opacity(0.35))
            }
            .background(Color.mSurface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.mBorder, lineWidth: 1))

            if let token = s.lastCheckpointToken {
                Text("Last checkpoint: \(token)")
                    .font(.mCaption)
                    .foregroundStyle(Color.mText.opacity(0.45))
            }
        }
    }

    private func tableRow(_ label: String, value: Int, icon: String, iconColor: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(iconColor).frame(width: 20)
            Text(label).font(.mBody).foregroundStyle(Color.mText)
            Spacer()
            Text("\(value)").font(.mBodySemi).foregroundStyle(Color.mText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Verify section

    private func verifySection(_ s: RecoverySummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Verify \(s.copiedUnverified) unconfirmed transfer\(s.copiedUnverified == 1 ? "" : "s")")
                    .font(.mBodySemi)
                    .foregroundStyle(Color.mText)
                Spacer()
                if vm.verifyState == .idle {
                    MPillButton("Verify now", icon: "checkmark.shield", style: .secondary) {
                        Task { await vm.verifyUnconfirmed() }
                    }
                }
            }
            if vm.verifyState != .idle {
                MProgressBar(value: vm.verifyTotal > 0 ? Double(vm.verifyDone) / Double(vm.verifyTotal) : 0)
                HStack {
                    Text("\(vm.verifyDone) / \(vm.verifyTotal)")
                        .font(.mCaption)
                        .foregroundStyle(Color.mText.opacity(0.6))
                    Spacer()
                    if vm.verifyState == .done {
                        Label("Done", systemImage: "checkmark.circle").font(.mCaption).foregroundStyle(Color.mSage)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func actionRow(_ s: RecoverySummary) -> some View {
        HStack(spacing: 12) {
            if let record = appVM.interruptedRun, appVM.canResume(record) {
                MPillButton("Resume run", icon: "play.fill") {
                    Task { await appVM.resumeRun(record: record) }
                }
                .disabled(vm.isReverting || vm.revertResult != nil || appVM.isExecuting)
            }

            if s.totalMovedFiles > 0 {
                MPillButton(
                    vm.isReverting ? "Reverting…" : "Revert \(s.totalMovedFiles) moved files",
                    icon: "arrow.uturn.backward",
                    style: .secondary
                ) { showRevertConfirm = true }
                .disabled(vm.isReverting || vm.revertResult != nil)
            }

            Spacer()

            MPillButton("Decide later", icon: "clock", style: .secondary) {
                appVM.dismissInterruptedRun()
            }
        }
        .confirmationDialog(
            "Revert \(s.totalMovedFiles) moved files?",
            isPresented: $showRevertConfirm,
            titleVisibility: .visible
        ) {
            Button("Revert", role: .destructive) { Task { await vm.revertRun() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Files will be moved back to their original locations. Memento cannot undo this step.")
        }
        .overlay(alignment: .center) {
            if let result = vm.revertResult {
                revertDoneChip(result)
            }
        }
    }

    private func revertDoneChip(_ result: (reverted: Int, failed: Int)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(result.failed == 0 ? Color.mSage : Color.mTerracotta)
            Text("Reverted \(result.reverted)\(result.failed > 0 ? ", \(result.failed) failed" : "")")
                .font(.mBodySemi)
                .foregroundStyle(Color.mText)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Color.mSurface)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
    }
}
