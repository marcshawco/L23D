import AppKit
import SwiftUI

/// Main window: status, pairing code, Blender status, and the job list.
struct HQWindow: View {
    @Environment(HQServerModel.self) private var model
    @State private var showFolderBuild = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            blenderBar
            Divider()
            if model.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No scans yet", systemImage: "desktopcomputer")
                } description: {
                    Text("On your iPhone, open a scan in L23D, tap •••, then Build HQ on Mac. Or build from a folder of photos taken with any camera.")
                } actions: {
                    Button("Build from Photos Folder…") { showFolderBuild = true }
                }
            } else {
                List(model.jobs) { job in
                    JobRowView(job: job)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
        .toolbar {
            ToolbarItem {
                Button("Build from Photos Folder…", systemImage: "folder.badge.plus") { showFolderBuild = true }
            }
        }
        .sheet(isPresented: $showFolderBuild) {
            FolderBuildSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshBlender()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("L23D HQ").font(.largeTitle.bold())
                if model.listeningPort != nil {
                    Label("Ready — visible to iPhones on this Wi-Fi as “\(model.serviceName)”", systemImage: "wifi")
                        .foregroundStyle(.green)
                } else if let problem = model.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Label("Starting…", systemImage: "hourglass")
                }
                if let client = model.lastClient {
                    Text("Last connected: \(client)").font(.callout).foregroundStyle(.secondary)
                }
                if model.listeningPort != nil, let problem = model.problem {
                    Text(problem).font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("Pairing code").font(.caption).foregroundStyle(.secondary)
                Text(model.pairingCode)
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                HStack {
                    Button("New Code") { Task { await model.resetCode() } }
                    Button("Show Jobs Folder") { model.revealJobsFolder() }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var blenderBar: some View {
        if model.blenderURL != nil {
            Label("Blender found — every model also gets a ready-to-render photoreal .blend scene.", systemImage: "checkmark.seal")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Label("Install Blender to get ready-to-render .blend scenes automatically.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Link("blender.org", destination: URL(string: "https://www.blender.org/download/")!)
            }
            .font(.callout)
        }
    }
}

private struct JobRowView: View {
    @Environment(HQServerModel.self) private var model
    let job: HQJobRow

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            preview
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.headline)
                Text("\(job.detail.title) detail · \(job.source == .iPhone ? "from iPhone" : "from folder") · \(job.started.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusView
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var preview: some View {
        if case .done(_, let scene?, _) = job.status, let url = scene.preview, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 128, height: 72)
                .overlay(Image(systemName: "cube.transparent").foregroundStyle(.secondary))
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch job.status {
        case .receiving(let fraction):
            progress("Receiving photos", fraction: fraction)
        case .building(let fraction, let stage):
            progress(stage, fraction: fraction)
        case .makingScene:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Making the Blender scene…").font(.caption)
            }
        case .done(let modelURL, let scene, let note):
            HStack {
                if job.source == .iPhone {
                    Label("Sent to iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                }
                if let scene {
                    Button("Open in Blender") { model.openInBlender(scene.blend) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Show in Finder") { model.reveal(scene?.blend ?? modelURL) }
            }
            .controlSize(.small)
            if let triangles = scene?.triangles {
                Text("\(triangles.formatted()) triangles").font(.caption).foregroundStyle(.secondary)
            }
            if let note {
                Text(note).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(3)
        }
    }

    private func progress(_ text: String, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(text) · \(fraction.formatted(.percent.precision(.fractionLength(0))))").font(.caption)
            ProgressView(value: fraction).frame(maxWidth: 260)
        }
    }
}

/// Pick a photos folder and a detail level.
private struct FolderBuildSheet: View {
    @Environment(HQServerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var detail: HQDetail = .full

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Build from Photos Folder").font(.title2.bold())
            Text("Use 50–200 sharp photos taken all the way around the subject, with lots of overlap. Photos from a good camera (or iPhone ProRAW exported as JPEG/HEIC) give the most photoreal result.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose Folder…") { choose() }
                Text(folder?.path(percentEncoded: false) ?? "No folder chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(folder == nil ? .secondary : .primary)
            }
            Picker("Detail", selection: $detail) {
                ForEach(HQDetail.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(detail.help).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Build") {
                    if let folder { model.buildFromFolder(folder, detail: detail) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(folder == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { folder = panel.url }
    }
}
