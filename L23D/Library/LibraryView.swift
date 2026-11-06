import SwiftUI
import SwiftData

/// Home screen: a grid of saved scans and a button to start a new one.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Scan.createdAt, order: .reverse) private var scans: [Scan]

    @State private var showNewScan = false
    @State private var showAbout = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
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
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(scans) { scan in
                                ScanCard(scan: scan)
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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("About", systemImage: "info.circle") { showAbout = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Scan", systemImage: "plus") { showNewScan = true }
                }
            }
            .sheet(isPresented: $showNewScan) {
                NewScanSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
        }
    }

    private func delete(_ scan: Scan) {
        ScanStore.deleteFiles(for: scan.id)
        modelContext.delete(scan)
    }
}

/// One tile in the library grid.
struct ScanCard: View {
    let scan: Scan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                Image(systemName: scan.mode.systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
            .aspectRatio(1, contentMode: .fit)

            Text(scan.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(scan.status.label)
                .font(.caption)
                .foregroundStyle(scan.status == .failed ? .red : .secondary)
        }
    }
}

/// Lets the user pick how to scan.
struct NewScanSheet: View {
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
                        .opacity(mode.isAvailable && DeviceSupport.canScan ? 1 : 0.5)
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

#Preview {
    LibraryView()
        .modelContainer(for: Scan.self, inMemory: true)
}
