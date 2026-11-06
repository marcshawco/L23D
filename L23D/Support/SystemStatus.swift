import Foundation
import Observation
import SwiftUI

/// Watches phone heat and free storage, and turns them into plain warnings.
@MainActor
@Observable
final class SystemStatus {
    private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var freeBytes: Int64?

    /// Warn below this much free space. One scan plus its build can use 1–2 GB.
    nonisolated static let lowStorageBytes: Int64 = 2_000_000_000

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        thermalState = ProcessInfo.processInfo.thermalState
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeBytes = values?.volumeAvailableCapacityForImportantUsage
    }

    var isTooHotToScan: Bool { thermalState == .critical }

    var thermalWarning: String? { Self.thermalWarning(for: thermalState) }

    var storageWarning: String? { Self.storageWarning(freeBytes: freeBytes) }

    var warnings: [String] { [thermalWarning, storageWarning].compactMap { $0 } }

    nonisolated static func thermalWarning(for state: ProcessInfo.ThermalState) -> String? {
        switch state {
        case .serious: "Your iPhone is warm. Scanning and building may slow down."
        case .critical: "Your iPhone is too hot. Let it cool down before scanning."
        default: nil
        }
    }

    nonisolated static func storageWarning(freeBytes: Int64?) -> String? {
        guard let freeBytes, freeBytes < lowStorageBytes else { return nil }
        return "Only \(Format.bytes(freeBytes)) free. A scan can use 1–2 GB — free up space first."
    }
}

/// Orange warning rows for heat and storage. Shows nothing when all is fine.
struct SystemWarningsView: View {
    @Environment(SystemStatus.self) private var status

    var body: some View {
        if !status.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(status.warnings, id: \.self) { warning in
                    Label(warning, systemImage: warning.contains("hot") || warning.contains("warm") ? "thermometer.high" : "externaldrive.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
