import SwiftUI

struct ProgressBanner: View {
    @Environment(AppViewModel.self) private var vm

    @State private var showCancelConfirmation = false

    var body: some View {
        Group {
            if let scanVM = vm.scanVM {
                scanBanner(scanVM)
            } else if vm.isExecuting, let prog = vm.activeExecutionProgress {
                executionBanner(prog)
            }
        }
        .confirmationDialog("Cancel this scan?", isPresented: $showCancelConfirmation) {
            Button("Cancel scan", role: .destructive) { vm.cancelScan() }
            Button("Keep scanning", role: .cancel) { }
        } message: {
            Text("Progress from this scan will be lost. Nothing has been moved or changed on disk.")
        }
    }

    private func scanBanner(_ vm: ScanViewModel) -> some View {
        HStack(spacing: 16) {
            // Phase label
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.mTerracotta)
                Text(vm.phase.rawValue)
                    .font(.mLabel)
                    .foregroundStyle(Color.mText)
            }
            .frame(width: 160, alignment: .leading)

            MDivider().frame(width: 1).frame(maxHeight: 20)

            // Stats
            statItem(label: "Found", value: "\(vm.foundItems)")
            statItem(label: "Videos", value: "\(vm.videoCount)")
            statItem(label: "No date", value: "\(vm.noDatesCount)")
            if vm.mbPerSecond > 0 {
                statItem(label: "MB/s", value: String(format: "%.1f", vm.mbPerSecond))
            }

            Spacer()

            // Progress bars for active phases
            if vm.metaTotal > 0 {
                phaseBar(label: "Metadata", done: vm.metaDone, total: vm.metaTotal, color: .mTerracotta)
            }
            if vm.hashTotal > 0 {
                phaseBar(label: "Hashing", done: vm.hashDone, total: vm.hashTotal, color: .mSage)
            }

            Spacer()

            MPillButton("Cancel", icon: "xmark", style: .secondary) {
                showCancelConfirmation = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.mSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.mText.opacity(0.08)).frame(height: 1)
        }
    }

    private func executionBanner(_ progress: ExecutionProgress) -> some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.mTerracotta)
                Text("Applying plan")
                    .font(.mLabel)
                    .foregroundStyle(Color.mText)
            }

            MDivider().frame(width: 1).frame(maxHeight: 20)

            statItem(label: "Done", value: "\(progress.completed) / \(progress.total)")
            statItem(label: "Transferred", value: progress.bytesTransferred.formattedFileSize)
            if !progress.currentFile.isEmpty {
                statItem(label: "Now", value: progress.currentFile)
            }

            Spacer()

            MProgressBar(value: progress.fraction)
                .frame(width: 160)

            Text("\(Int(progress.fraction * 100))%")
                .font(.mBodySemi)
                .foregroundStyle(Color.mText)
                .frame(width: 36)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.mSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.mText.opacity(0.08)).frame(height: 1)
        }
    }

    private func statItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.mBodySemi).foregroundStyle(Color.mText)
            Text(label).font(.mCaption).foregroundStyle(Color.mText.opacity(0.55))
        }
    }

    private func phaseBar(label: String, done: Int, total: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(label).font(.mCaption).foregroundStyle(Color.mText.opacity(0.6))
                Spacer()
                Text("\(done)/\(total)").font(.mCaption).foregroundStyle(Color.mText.opacity(0.4))
            }
            MProgressBar(value: total > 0 ? Double(done) / Double(total) : 0, color: color)
        }
        .frame(width: 130)
    }
}
