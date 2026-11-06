import RealityKit
import SwiftUI

/// Full-screen guided capture for a still object, built on Apple's Object Capture.
///
/// Steps: start camera → point at object → fit the box → walk around (auto photos)
/// → after each lap: flip / new height / finish → photos saved → caller builds the model.
struct ObjectCaptureFlowView: View {
    enum Outcome {
        /// Photos are saved in the scan's Images folder.
        case completed(imageCount: Int)
        case cancelled
    }

    let folder: ScanFolder
    let onFinish: (Outcome) -> Void

    @State private var session: ObjectCaptureSession?
    @State private var setupError: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                ObjectCaptureContent(session: session, folder: folder, onFinish: onFinish)
            } else if let setupError {
                CaptureErrorView(message: setupError) { onFinish(.cancelled) }
            } else {
                ProgressView("Starting camera…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .task { startSession() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .statusBarHidden()
    }

    private func startSession() {
        guard session == nil else { return }
        do {
            try folder.create()
            try folder.resetCapture() // Object Capture needs an empty folder.
        } catch {
            setupError = "Couldn't prepare storage: \(error.localizedDescription)"
            return
        }
        let newSession = ObjectCaptureSession()
        var configuration = ObjectCaptureSession.Configuration()
        // Shared with the model build later, so building starts faster.
        configuration.checkpointDirectory = folder.checkpoint
        // Saves extra photos that a Mac can use later for higher detail (HQ mode).
        configuration.isOverCaptureEnabled = true
        newSession.start(imagesDirectory: folder.images, configuration: configuration)
        session = newSession
    }
}

/// The live capture UI. Reads the session directly (it is Observable).
private struct ObjectCaptureContent: View {
    let session: ObjectCaptureSession
    let folder: ScanFolder
    let onFinish: (ObjectCaptureFlowView.Outcome) -> Void

    @State private var passNumber = 1
    @State private var showPassSheet = false
    @State private var confirmCancel = false
    @State private var didFinish = false

    var body: some View {
        ZStack {
            switch session.state {
            case .ready, .detecting, .capturing:
                ObjectCaptureView(session: session)
                    .ignoresSafeArea()
            case .initializing:
                ProgressView("Starting camera…").tint(.white).foregroundStyle(.white)
            case .finishing:
                ProgressView("Saving photos…").tint(.white).foregroundStyle(.white)
            case .completed:
                ProgressView("Done").tint(.white).foregroundStyle(.white)
            case .failed(let error):
                CaptureErrorView(message: Self.describe(error)) { finish(.cancelled) }
            @unknown default:
                ProgressView().tint(.white)
            }

            if session.state.showsControls {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .padding()
            }
        }
        .onChange(of: session.userCompletedScanPass) { _, completed in
            if completed { showPassSheet = true }
        }
        .onChange(of: session.state) { _, state in
            if case .completed = state {
                finish(.completed(imageCount: folder.imageCount))
            }
        }
        .sheet(isPresented: $showPassSheet) {
            ScanPassSheet(session: session, passNumber: passNumber) { choice in
                showPassSheet = false
                switch choice {
                case .flip:
                    passNumber += 1
                    session.beginNewScanPassAfterFlip()
                case .newHeight:
                    passNumber += 1
                    session.beginNewScanPass()
                case .finish:
                    session.finish()
                }
            }
            .interactiveDismissDisabled()
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                session.cancel()
                finish(.cancelled)
            }
            Button("Keep scanning", role: .cancel) {}
        }
    }

    private var topBar: some View {
        HStack(alignment: .top) {
            Button {
                confirmCancel = true
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Cancel scan")

            Spacer()

            if let message = session.feedback.firstMessage {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }

            Spacer()

            if case .capturing = session.state {
                Text("\(session.numberOfShotsTaken)/\(session.maximumNumberOfInputImages)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut, value: session.feedback.firstMessage)
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 12) {
            Text(instruction)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 12) {
                switch session.state {
                case .ready:
                    Button("Continue") { _ = session.startDetecting() }
                        .buttonStyle(.borderedProminent)
                case .detecting:
                    Button("Reset Box") { session.resetDetection() }
                        .buttonStyle(.bordered)
                    Button("Start Capture") { session.startCapturing() }
                        .buttonStyle(.borderedProminent)
                case .capturing:
                    Button("Finish") { session.finish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(session.numberOfShotsTaken < 10)
                default:
                    EmptyView()
                }
            }
            .controlSize(.large)
        }
    }

    private var instruction: String {
        switch session.state {
        case .ready:
            "Put the object on a plain surface with space all around it. Point the camera at it."
        case .detecting:
            "Drag the box edges so it fits snugly around the object."
        case .capturing:
            "Pass \(passNumber): walk slowly around the object. Keep it in view."
        default:
            ""
        }
    }

    private func finish(_ outcome: ObjectCaptureFlowView.Outcome) {
        guard !didFinish else { return }
        didFinish = true
        onFinish(outcome)
    }

    static func describe(_ error: any Error) -> String {
        if let captureError = error as? ObjectCaptureSession.Error {
            switch captureError {
            case .insufficientStorage:
                return "Your iPhone is low on storage. Free up some space and try again."
            case .trackingFailed:
                return "The camera lost track of where it was. Try again with more light and slower moves."
            case .sensorFailed:
                return "The camera or LiDAR sensor stopped working. Restart the app and try again."
            case .cancelled:
                return "The scan was cancelled."
            case .directoryNotEmpty:
                return "Couldn't start because old photos were in the way. Try again."
            @unknown default:
                return captureError.localizedDescription
            }
        }
        return error.localizedDescription
    }
}

/// Shown after each lap around the object.
private struct ScanPassSheet: View {
    enum Choice { case flip, newHeight, finish }

    let session: ObjectCaptureSession
    let passNumber: Int
    let onChoose: (Choice) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ObjectCapturePointCloudView(session: session)
                    .frame(maxWidth: .infinity)
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text("This is what has been captured so far. For the best model, do 3 laps: low, middle, and high — or flip the object to get its bottom.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 10) {
                    Button {
                        onChoose(.flip)
                    } label: {
                        Label("Flip Object & Scan Again", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.feedback.contains(.objectNotFlippable))

                    Button {
                        onChoose(.newHeight)
                    } label: {
                        Label("Scan Again From Another Height", systemImage: "arrow.up.and.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onChoose(.finish)
                    } label: {
                        Label("Finish & Build Model", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("Lap \(passNumber) done")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }
}

struct CaptureErrorView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("Close", action: onClose)
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

private extension ObjectCaptureSession.CaptureState {
    var showsControls: Bool {
        switch self {
        case .ready, .detecting, .capturing: true
        default: false
        }
    }
}

extension Set where Element == ObjectCaptureSession.Feedback {
    /// The most useful single hint to show, in plain words.
    var firstMessage: String? {
        // Order matters: show the most important problem first.
        let priority: [ObjectCaptureSession.Feedback] = [
            .environmentTooDark, .environmentLowLight, .movingTooFast,
            .outOfFieldOfView, .objectNotDetected, .objectTooClose, .objectTooFar, .overCapturing,
        ]
        for feedback in priority where contains(feedback) {
            return feedback.message
        }
        return nil
    }
}

extension ObjectCaptureSession.Feedback {
    var message: String {
        switch self {
        case .objectTooClose: "Move farther away"
        case .objectTooFar: "Move closer"
        case .movingTooFast: "Slow down"
        case .environmentLowLight: "More light would help"
        case .environmentTooDark: "Too dark to scan"
        case .outOfFieldOfView: "Keep the object in view"
        case .objectNotFlippable: "This object shouldn't be flipped"
        case .overCapturing: "Enough photos here — keep moving"
        case .objectNotDetected: "Can't find the object"
        @unknown default: "Keep going"
        }
    }
}
