import SwiftData
import SwiftUI

/// "Build on Mac": pick a Mac and a detail level, send the photos, get an HQ model back.
struct HQSendSheet: View {
    @Bindable var scan: Scan

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var browser = HQBrowser()
    @State private var transfer = HQTransfer()
    @State private var selectedMac: HQMac?
    @State private var pairingCode = ""
    @State private var detail: HQDetail = .full

    var body: some View {
        NavigationStack {
            Form {
                if transfer.phase == .idle || isFailed {
                    setupSections
                } else {
                    progressSection
                }
            }
            .navigationTitle("Build on Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(transfer.phase.isActive ? "Stop" : "Close") {
                        transfer.cancel()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(transfer.phase.isActive)
            .onAppear { browser.start() }
            .onDisappear {
                browser.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChange(of: transfer.phase) { _, phase in
                UIApplication.shared.isIdleTimerDisabled = phase.isActive
                if case .done = phase { Task { await adoptHQModel() } }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var setupSections: some View {
        Section {
            if browser.macs.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for Macs running L23D HQ…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(browser.macs) { mac in
                Button {
                    selectedMac = mac
                    pairingCode = HQPairing.code(for: mac.name) ?? ""
                } label: {
                    HStack {
                        Label(mac.name, systemImage: "desktopcomputer")
                        Spacer()
                        if selectedMac == mac { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .foregroundStyle(.primary)
            }
            if let problem = browser.problem {
                Text(problem).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Mac")
        } footer: {
            Text("Open L23D HQ on your Mac. Both devices must be on the same Wi-Fi.")
        }

        if selectedMac != nil {
            Section {
                TextField("6-digit code", text: $pairingCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
            } header: {
                Text("Pairing code")
            } footer: {
                Text("Shown in the L23D HQ window on your Mac. Saved after the first time.")
            }
        }

        Section {
            Picker("Detail", selection: $detail) {
                ForEach(HQDetail.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            Text(detail.help)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Detail")
        }

        Section {
            Button {
                Task { await send() }
            } label: {
                Label("Send \(scan.imageCount > 0 ? "\(scan.imageCount) Photos" : "Photos")", systemImage: "paperplane")
                    .frame(maxWidth: .infinity)
            }
            .disabled(selectedMac == nil || pairingCode.count < 6)
        } footer: {
            if case .failed(let message) = transfer.phase {
                Text(message).foregroundStyle(.red)
            } else {
                Text("Keep L23D open on your iPhone until the model comes back. Building can take several minutes.")
            }
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                switch transfer.phase {
                case .connecting:
                    Label("Connecting to \(selectedMac?.name ?? "Mac")…", systemImage: "wifi")
                    ProgressView()
                case .uploading(let fraction):
                    Label("Sending photos", systemImage: "arrow.up.circle")
                    ProgressView(value: fraction)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.caption).foregroundStyle(.secondary)
                case .building(let fraction, let stage):
                    Label("Building on the Mac (\(detail.title))", systemImage: "desktopcomputer")
                    ProgressView(value: fraction)
                    Text("\(stage) · \(fraction.formatted(.percent.precision(.fractionLength(0))))").font(.caption).foregroundStyle(.secondary)
                case .downloading(let fraction):
                    Label("Getting the model", systemImage: "arrow.down.circle")
                    ProgressView(value: fraction)
                case .done:
                    Label("HQ model ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = transfer.phase { true } else { false }
    }

    // MARK: - Actions

    private func send() async {
        guard let mac = selectedMac else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespaces)
        await transfer.run(
            folder: scan.folder, scanName: scan.name, mode: scan.mode, detail: detail,
            endpoint: mac.endpoint, pairingCode: code, destination: scan.folder.hqModelFile
        )
        switch transfer.phase {
        case .done:
            HQPairing.save(code, for: mac.name)
        case .failed(let message) where message.contains("pairing code"):
            HQPairing.forget(mac.name)
        default:
            break
        }
    }

    /// Switch the scan to the HQ model and refresh its facts and thumbnail.
    private func adoptHQModel() async {
        let folder = scan.folder
        scan.hqDetail = detail
        if let stats = try? await ModelInspector.stats(for: folder.hqModelFile) {
            scan.triangleCount = stats.triangleCount
            scan.size = SIMD3(Double(stats.size.x), Double(stats.size.y), Double(stats.size.z))
        }
        await ModelInspector.writeThumbnail(for: folder.hqModelFile, to: folder.thumbnail)
        try? modelContext.save()
    }
}
