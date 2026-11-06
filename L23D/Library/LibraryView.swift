import SwiftData
import SwiftUI

/// Home screen: a grid of saved scans and a button to start a new one.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ReconstructionCenter.self) private var reconstruction
    @Query(sort: \Scan.createdAt, order: .reverse) private var scans: [Scan]

    @State private var path: [Scan] = []
    @State private var showNewScan = false
    @State private var showAbout = false
    @State private var pendingMode: ScanMode?
    @State private var capturingScan: Scan?
    @State private var justCaptured: Scan?
    @State private var errorMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if scans.isEmpty {
                    ContentUnavailableView {
                        Label("No scans yet", systemImage: "cube.transparent")
                    } description: {
                        Text("Tap New Scan to turn an object or a person into a 3D model.")
                    } actions: {
                        Button("New Scan") { showNewScan = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(scans) { scan in
                                NavigationLink(value: scan) {
                                    ScanCard(scan: scan, job: reconstruction.job(for: scan.id))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        delete(scan)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("L23D")
            .navigationDestination(for: Scan.self) { scan in
                ScanDetailView(scan: scan)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("About", systemImage: "info.circle") { showAbout = true }
                        #if DEBUG
                        Button("Add Sample Model", systemImage: "shippingbox") { addSample() }
                        #endif
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Scan", systemImage: "plus") { showNewScan = true }
                }
            }
            .sheet(isPresented: $showNewScan, onDismiss: startPendingCapture) {
                NewScanSheet { mode in
                    pendingMode = mode
                    showNewScan = false
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
            .fullScreenCover(item: $capturingScan, onDismiss: buildJustCaptured) { scan in
                switch scan.mode {
                case .object:
                    ObjectCaptureFlowView(folder: scan.folder) { outcome in
                        handleCaptureOutcome(outcome, for: scan)
                    }
                case .personHelper:
                    HelperCaptureView(folder: scan.folder) { outcome in
                        handleCaptureOutcome(outcome, for: scan)
                    }
                case .personSpin:
                    SpinCaptureView(folder: scan.folder) { outcome in
                        handleCaptureOutcome(outcome, for: scan)
                    }
                }
            }
            .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Capture flow

    private func startPendingCapture() {
        guard let mode = pendingMode else { return }
        pendingMode = nil
        guard mode.isAvailable else { return }
        let scan = Scan(name: Scan.defaultName(for: mode), mode: mode)
        modelContext.insert(scan)
        try? modelContext.save()
        capturingScan = scan
    }

    private func handleCaptureOutcome(_ outcome: ObjectCaptureFlowView.Outcome, for scan: Scan) {
        switch outcome {
        case .completed(let imageCount):
            scan.imageCount = imageCount
            scan.status = .captured
            try? modelContext.save()
            justCaptured = scan
        case .cancelled:
            delete(scan)
        }
        capturingScan = nil
    }

    /// Runs after the capture screen is gone, so the camera session is fully released
    /// before the (memory-hungry) model build starts.
    private func buildJustCaptured() {
        guard let scan = justCaptured else { return }
        justCaptured = nil
        reconstruction.enqueue(scan)
        path.append(scan)
    }

    // MARK: - Library actions

    private func delete(_ scan: Scan) {
        reconstruction.cancel(scan.id)
        ScanStore.deleteFiles(for: scan.id)
        modelContext.delete(scan)
        try? modelContext.save()
    }

    #if DEBUG
    private func addSample() {
        Task {
            do {
                _ = try await SampleModel.addSampleScan(to: modelContext)
            } catch {
                errorMessage = "Couldn't make the sample model: \(error.localizedDescription)"
            }
        }
    }
    #endif
}

/// One tile in the library grid.
struct ScanCard: View {
    let scan: Scan
    let job: ReconstructionJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary)
                if let thumbnail = UIImage(contentsOfFile: scan.folder.thumbnail.path(percentEncoded: false)) {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: scan.mode.systemImage)
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
                if scan.status == .processing, let job {
                    VStack {
                        Spacer()
                        ProgressView(value: job.fraction)
                            .padding(10)
                            .background(.ultraThinMaterial)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(scan.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(scan.status == .failed ? .red : .secondary)
        }
        .contentShape(Rectangle())
    }

    private var statusText: String {
        if scan.status == .processing, let job {
            return "Building · \(job.fraction.formatted(.percent.precision(.fractionLength(0))))"
        }
        return scan.status.label
    }
}

/// Lets the user pick how to scan.
struct NewScanSheet: View {
    let onPick: (ScanMode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let reason = DeviceSupport.unsupportedReason {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section("What are you scanning?") {
                    ForEach(ScanMode.allCases) { mode in
                        Button {
                            onPick(mode)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: mode.systemImage)
                                    .font(.title2)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.title).font(.headline)
                                    Text(mode.isAvailable ? mode.subtitle : "Coming soon")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .disabled(!mode.isAvailable || !DeviceSupport.canScan)
                    }
                }
            }
            .navigationTitle("New Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Version", value: Bundle.main.versionString)
                LabeledContent("LiDAR", value: DeviceSupport.hasLiDAR ? "Yes" : "No")
                LabeledContent("Can scan", value: DeviceSupport.canScan ? "Yes" : "No")
                Section {
                    Text("Models are built on this iPhone. Apple limits on-phone models to its \"reduced\" detail level, which works well for games and AR.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("About L23D")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
