import SwiftUI

struct ScanView: View {
    @Environment(AppViewModel.self) private var vm

    @State private var showCancelConfirmation = false

    var body: some View {
        if let scanVM = vm.scanVM {
            scanningView(scanVM)
        } else if vm.isExecuting, let prog = vm.activeExecutionProgress {
            executingView(prog)
        } else {
            VStack(spacing: 0) {
                MScreenHeader("Scanning")
                EmptyState(icon: "magnifyingglass", title: "No active scan",
                           message: "Start a new run from the sidebar.")
            }
        }
    }

    // MARK: - Scanning

    private func scanningView(_ scanVM: ScanViewModel) -> some View {
        // TimelineView ticks once a second so the active phase's elapsed time keeps moving
        // regardless of how often the pipeline reports progress.
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
            scanningContent(scanVM, now: context.date)
        }
    }

    private func scanningContent(_ scanVM: ScanViewModel, now: Date) -> some View {
        let elapsed = scanVM.phase == .ready || scanVM.phase == .cancelled ? "" : scanVM.elapsedString(at: now)
        return VStack(spacing: 0) {
            MScreenHeader("Scanning", subtitle: scanVM.totalDurationString ?? scanVM.phase.rawValue)
            ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                // Stats row
                HStack(spacing: 12) {
                    MStatPill(value: "\(scanVM.foundItems)", label: "Found")
                    MStatPill(value: "\(scanVM.videoCount)", label: "Videos")
                    MStatPill(value: "\(scanVM.noDatesCount)", label: "No date")
                    MStatPill(value: "\(scanVM.duplicateSetsCount)", label: "Dup sets")
                    if scanVM.mbPerSecond > 0 {
                        MStatPill(value: String(format: "%.1f", scanVM.mbPerSecond), label: "MB/s")
                    }
                }

                // Phase progress bars
                MCard {
                    VStack(spacing: 20) {
                        phaseRow(
                            label: "Indexing files",
                            detail: scanVM.durationDetail(for: .indexing)
                                ?? "\(scanVM.foundItems) items\(scanVM.phase == .indexing ? " · \(elapsed)" : "")",
                            value: ScanViewModel.Phase.indexing.isDone(relativeTo: scanVM.phase) ? 1 : nil,
                            active: scanVM.phase == .indexing,
                            color: .mTerracotta
                        )
                        MDivider()
                        phaseRow(
                            label: "Reading metadata",
                            detail: scanVM.durationDetail(for: .readingMetadata)
                                ?? (scanVM.metaTotal > 0
                                    ? "\(scanVM.metaDone) / \(scanVM.metaTotal)\(scanVM.phase == .readingMetadata ? " · \(elapsed)" : "")"
                                    : ""),
                            value: ScanViewModel.Phase.readingMetadata.isDone(relativeTo: scanVM.phase)
                                ? 1
                                : (scanVM.metaTotal > 0 ? Double(scanVM.metaDone) / Double(scanVM.metaTotal) : nil),
                            active: scanVM.phase == .readingMetadata,
                            color: .mTerracotta
                        )
                        MDivider()
                        phaseRow(
                            label: "Computing checksums",
                            detail: scanVM.durationDetail(for: .hashing) ?? scanVM.hashDetail(elapsed: elapsed),
                            value: ScanViewModel.Phase.hashing.isDone(relativeTo: scanVM.phase)
                                ? 1
                                : (scanVM.hashTotal > 0 ? Double(scanVM.hashDone) / Double(scanVM.hashTotal) : nil),
                            active: scanVM.phase == .hashing,
                            color: .mSage
                        )
                        if scanVM.runsFaceDetection {
                        MDivider()
                        phaseRow(
                            label: "Face clustering",
                            detail: scanVM.durationDetail(for: .detectingFaces)
                                ?? (scanVM.phase == .detectingFaces
                                    ? (scanVM.faceTotal > 0 ? "\(scanVM.faceDone) / \(scanVM.faceTotal) · \(elapsed)" : elapsed)
                                    : ""),
                            value: ScanViewModel.Phase.detectingFaces.isDone(relativeTo: scanVM.phase)
                                ? 1
                                : (scanVM.phase == .detectingFaces && scanVM.faceTotal > 0
                                    ? Double(scanVM.faceDone) / Double(scanVM.faceTotal) : nil),
                            active: scanVM.phase == .detectingFaces,
                            color: .mSage
                        )
                        }
                        MDivider()
                        phaseRow(
                            label: "Grouping events",
                            detail: scanVM.durationDetail(for: .grouping)
                                ?? (scanVM.phase == .grouping || scanVM.phase == .classifying ? elapsed : ""),
                            value: scanVM.phase == .ready ? 1 : nil,
                            active: scanVM.phase == .grouping,
                            color: .mTerracotta
                        )
                    }
                    .padding(24)
                }

                // Log tail
                if !scanVM.scanProgress.currentPath.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        MSectionHeader(title: "Current file")
                        Text(scanVM.scanProgress.currentPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Color.mText.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                // Actions
                HStack(spacing: 12) {
                    MPillButton("Cancel", icon: "xmark", style: .secondary) {
                        showCancelConfirmation = true
                    }
                    Spacer()
                    if scanVM.phase == .ready {
                        MPillButton("Review plan", icon: "arrow.right", style: .primary) {
                            vm.selectedSection = .plan
                        }
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: 680)
            }
            .background(Color.mGround)
        }
        .confirmationDialog("Cancel this scan?", isPresented: $showCancelConfirmation) {
            Button("Cancel scan", role: .destructive) { vm.cancelScan() }
            Button("Keep scanning", role: .cancel) { }
        } message: {
            Text("Progress from this scan will be lost. Nothing has been moved or changed on disk.")
        }
    }

    // MARK: - Executing

    private func executingView(_ progress: ExecutionProgress) -> some View {
        VStack(spacing: 0) {
            MScreenHeader("Applying plan", subtitle: "\(progress.completed) of \(progress.total) files transferred")
            executingBody(progress)
        }
    }

    private func executingBody(_ progress: ExecutionProgress) -> some View {
        VStack(alignment: .leading, spacing: 36) {

            VStack(spacing: 8) {
                MProgressBar(value: progress.fraction)
                    .frame(height: 8)
                HStack {
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.mBodySemi)
                        .foregroundStyle(Color.mTerracotta)
                    Spacer()
                    Text(progress.bytesTransferred.formattedFileSize + " transferred")
                        .font(.mCaption)
                        .foregroundStyle(Color.mText.opacity(0.5))
                }
            }

            HStack(spacing: 12) {
                MStatPill(value: "\(progress.completed)", label: "Moved")
                MStatPill(value: "\(progress.failed)", label: "Failed")
                MStatPill(value: "\(progress.quarantined)", label: "Quarantined")
                if progress.alreadyPresent > 0 {
                    MStatPill(value: "\(progress.alreadyPresent)", label: "Already there")
                }
            }

            if !progress.currentFile.isEmpty {
                Text("↳ \(progress.currentFile)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.mText.opacity(0.4))
            }
            if !progress.lastCheckpointToken.isEmpty {
                Text("Checkpoint: \(progress.lastCheckpointToken)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Color.mText.opacity(0.3))
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: 680, maxHeight: .infinity)
        .background(Color.mGround)
    }

    // MARK: - Phase row

    private func phaseRow(
        label: String, detail: String,
        value: Double?, active: Bool, color: Color
    ) -> some View {
        HStack(spacing: 16) {
            // Active always shows spinner; completed shows checkmark; else dot.
            ZStack {
                Circle()
                    .fill(active ? color.opacity(0.15) : (value == 1 ? color : Color.mText.opacity(0.06)))
                    .frame(width: 28, height: 28)
                if active {
                    ProgressView().controlSize(.mini).tint(color)
                } else if value == 1 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .fill(Color.mText.opacity(0.15))
                        .frame(width: 8, height: 8)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(label)
                        .font(.mBodySemi)
                        .foregroundStyle(active ? color : Color.mText)
                    Spacer()
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.mCaption)
                            .foregroundStyle(Color.mText.opacity(0.5))
                    }
                }
                if let v = value, v < 1 && active {
                    MProgressBar(value: v, color: color)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, active ? 6 : 0)
        .background(active ? color.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: active)
    }
}
