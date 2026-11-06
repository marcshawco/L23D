import BackgroundTasks
import Foundation

/// Lets a model build keep running after the user leaves the app (iOS 26 continued
/// processing). iOS shows its own progress UI and may stop the task when the system
/// is busy or hot; then the build is cancelled and can resume from its checkpoint.
@MainActor
final class BackgroundBuildTask {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in Config/Info.plist (with `.*`).
    static let identifierPrefix = "com.marcshawco.L23D.build"

    private var task: BGContinuedProcessingTask?
    private var finished = false

    /// Asks iOS for background time. Safe to call when unsupported (Simulator): it just does nothing.
    func begin(scanName: String, onExpire: @escaping @MainActor () -> Void) {
        let identifier = "\(Self.identifierPrefix).\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask, let self, !self.finished else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.task = task
                task.progress.totalUnitCount = 100
                task.expirationHandler = {
                    Task { @MainActor in onExpire() }
                }
            }
        }
        guard registered else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Building 3D model", subtitle: scanName)
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)
    }

    func update(fraction: Double, stage: String?) {
        guard let task else { return }
        task.progress.completedUnitCount = Int64((fraction * 100).rounded())
        if let stage {
            task.updateTitle("Building 3D model", subtitle: stage)
        }
    }

    func end(success: Bool) {
        finished = true
        task?.setTaskCompleted(success: success)
        task = nil
    }
}
