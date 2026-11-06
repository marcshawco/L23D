import QuickLook
import SwiftData
import SwiftUI

/// One scan: 3D preview, build progress, facts, and actions (AR, share, export).
struct ScanDetailView: View {
    @Bindable var scan: Scan

    @Environment(ReconstructionCenter.self) private var reconstruction
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var quickLookURL: URL?
    @State private var showRename = false
    @State private var draftName = ""
    @State private var confirmDelete = false
    @State private var diskUsage: Int64?
    @State private var showExport = false
    @State private var confirmDeletePhotos = false
    @State private var showHQ = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                preview
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                SystemWarningsView()

                statusSection

                if scan.status == .ready {
                    actions
                }

                details
            }
            .padding()
        }
        .navigationTitle(scan.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        draftName = scan.name
                        showRename = true
                    }
                    if canRebuild {
                        Button("Rebuild Model", systemImage: "arrow.clockwise") {
                            reconstruction.enqueue(scan)
                        }
                    }
                    if scan.status == .ready, scan.folder.imageCount > 0 {
                        Button("Build HQ on Mac…", systemImage: "desktopcomputer") { showHQ = true }
                    }
                    if scan.hqDetail != nil {
                        Button("Use Phone Model", systemImage: "iphone") {
                            Task { await usePhoneModel() }
                        }
                    }
                    if scan.status == .ready, scan.folder.imageCount > 0 {
                        Button("Delete Photos, Keep Model", systemImage: "photo.badge.minus") {
                            confirmDeletePhotos = true
                        }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        confirmDelete = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .quickLookPreview($quickLookURL)
        .sheet(isPresented: $showExport) {
            ExportSheet(scan: scan)
        }
        .sheet(isPresented: $showHQ) {
            HQSendSheet(scan: scan)
        }
        .alert("Rename Scan", isPresented: $showRename) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { scan.name = trimmed }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete the photos?", isPresented: $confirmDeletePhotos, titleVisibility: .visible) {
            Button("Delete Photos", role: .destructive) { deletePhotos() }
        } message: {
            Text("This frees up space. The 3D model and exports stay, but you won't be able to rebuild the model.")
        }
        .confirmationDialog("Delete this scan?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteScan() }
        } message: {
            Text("The photos and the 3D model will be removed from this iPhone.")
        }
        .task(id: scan.status) {
            let folder = scan.folder
            diskUsage = await Task.detached { folder.diskUsage }.value
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var preview: some View {
        if scan.status == .ready, scan.folder.hasModel {
            ModelViewer(url: scan.folder.activeModelFile)
                .id("\(scan.status.rawValue)-\(scan.hqDetailRaw ?? "phone")") // reload after a rebuild or HQ swap
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(.quaternary)
                Image(systemName: scan.mode.systemImage)
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch scan.status {
        case .processing:
            if let job = reconstruction.job(for: scan.id) {
                BuildProgressView(job: job) {
                    reconstruction.cancel(scan.id)
                }
            } else {
                ProgressView("Building…")
            }
        case .captured, .failed:
            VStack(spacing: 10) {
                if let message = scan.failureMessage {
                    Label(message, systemImage: scan.status == .failed ? "exclamationmark.triangle" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(scan.status == .failed ? .red : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if scan.imageCount > 0 || scan.folder.imageCount > 0 {
                    Button {
                        reconstruction.enqueue(scan)
                    } label: {
                        Label(scan.status == .failed ? "Try Again" : "Build Model", systemImage: "cube.transparent")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Text("This scan has no photos. Delete it and scan again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        case .capturing:
            Text("Capture didn't finish. Delete this scan and try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .ready:
            EmptyView()
        }
    }

    private var actions: some View {
        let model = scan.folder.activeModelFile
        return VStack(spacing: 12) {
            Button {
                showExport = true
            } label: {
                Label("Export for Games & 3D Apps", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 12) {
                Button {
                    quickLookURL = model
                } label: {
                    Label("View in AR", systemImage: "arkit")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                ShareLink(item: model, preview: SharePreview(scan.name)) {
                    Label("Share USDZ", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
    }

    private var details: some View {
        VStack(spacing: 0) {
            DetailRow(title: "Type", value: scan.mode.title)
            DetailRow(title: "Status", value: scan.status.label)
            if scan.status == .ready {
                DetailRow(title: "Model", value: scan.hqDetail.map { "HQ · \($0.title) (built on Mac)" } ?? "Phone (reduced detail)")
            }
            if let size = scan.size {
                DetailRow(title: "Size", value: Format.sizeInCentimeters(size))
            }
            if let triangles = scan.triangleCount {
                DetailRow(title: "Triangles", value: triangles.formatted())
            }
            DetailRow(title: "Photos", value: "\(max(scan.imageCount, 0))")
            if let diskUsage {
                DetailRow(title: "Storage", value: Format.bytes(diskUsage))
            }
            DetailRow(title: "Created", value: scan.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private var canRebuild: Bool {
        scan.status != .processing && scan.status != .capturing && scan.folder.imageCount > 0
    }

    private func usePhoneModel() async {
        let folder = scan.folder
        try? FileManager.default.removeItem(at: folder.hqModelFile)
        scan.hqDetail = nil
        if let stats = try? await ModelInspector.stats(for: folder.modelFile) {
            scan.triangleCount = stats.triangleCount
            scan.size = SIMD3(Double(stats.size.x), Double(stats.size.y), Double(stats.size.z))
        }
        await ModelInspector.writeThumbnail(for: folder.modelFile, to: folder.thumbnail)
        try? modelContext.save()
    }

    private func deletePhotos() {
        do {
            try scan.folder.deleteCaptureData()
            scan.imageCount = 0
            try? modelContext.save()
            let folder = scan.folder
            Task { diskUsage = await Task.detached { folder.diskUsage }.value }
        } catch {
            scan.failureMessage = "Couldn't delete the photos: \(error.localizedDescription)"
        }
    }

    private func deleteScan() {
        reconstruction.cancel(scan.id)
        ScanStore.deleteFiles(for: scan.id)
        modelContext.delete(scan)
        try? modelContext.save()
        dismiss()
    }
}

/// Progress bar, stage name and time left for a model build.
struct BuildProgressView: View {
    let job: ReconstructionJob
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.stage ?? "Building model")
                    .font(.headline)
                Spacer()
                Text(job.fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.headline.monospacedDigit())
            }
            ProgressView(value: job.fraction)
            HStack {
                Text(job.remainingText ?? "You can switch apps — iOS keeps building for a while.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let onCancel {
                    Button("Cancel", role: .cancel, action: onCancel)
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}
