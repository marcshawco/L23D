import SwiftUI

/// Main window: status, pairing code, and the job list.
struct HQWindow: View {
    @Environment(HQServerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            if model.jobs.isEmpty {
                ContentUnavailableView {
                    Label("No scans yet", systemImage: "desktopcomputer")
                } description: {
                    Text("On your iPhone, open a scan in L23D, tap •••, then Build HQ on Mac.")
                }
            } else {
                List(model.jobs) { job in
                    JobRowView(job: job)
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
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
}

private struct JobRowView: View {
    @Environment(HQServerModel.self) private var model
    let job: HQJobRow

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.headline)
                Text("\(job.detail.title) detail · \(job.started.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch job.status {
            case .receiving(let fraction):
                status("Receiving photos", fraction: fraction)
            case .building(let fraction, let stage):
                status(stage, fraction: fraction)
            case .done(let url):
                Label("Sent to iPhone", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Show in Finder") { model.reveal(url) }
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private func status(_ text: String, fraction: Double) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text).font(.caption)
            ProgressView(value: fraction).frame(width: 160)
        }
    }
}
