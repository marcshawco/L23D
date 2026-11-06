import AVFoundation
import SwiftUI

/// Full-screen capture for "phone on a tripod, person turns on a swivel chair".
/// Works solo: there's a countdown to sit down, and spoken cues during the spin.
struct SpinCaptureView: View {
    let folder: ScanFolder
    let onFinish: (ObjectCaptureFlowView.Outcome) -> Void

    @State private var model = SpinCaptureModel()
    @State private var engine: SpinCaptureEngine?
    @State private var voice: VoiceGuide?
    @State private var timeline: Task<Void, Never>?
    @State private var confirmCancel = false
    @State private var didFinish = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine {
                CameraPreview(session: engine.captureSession).ignoresSafeArea()
            }

            switch model.phase {
            case .failed(let message):
                CaptureErrorView(message: message) { finish(.cancelled) }
            case .saving, .done:
                ProgressView("Saving photos…").tint(.white).foregroundStyle(.white)
            case .starting:
                ProgressView("Starting camera…").tint(.white).foregroundStyle(.white)
            default:
                overlay
            }
        }
        .statusBarHidden()
        .task { setUp() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { tearDown() }
        .onChange(of: model.phase) { _, phase in
            guard case .done(let count) = phase else { return }
            if count < SpinCaptureModel.minimumShots / 2 {
                model.phase = .failed("Only \(count) usable photos were saved. Check the light, make sure you're in the middle of the frame, and turn more slowly.")
            } else {
                finish(.completed(imageCount: count))
            }
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { finish(.cancelled) }
            Button("Keep scanning", role: .cancel) {}
        }
    }

    // MARK: - Overlay

    private var overlay: some View {
        VStack {
            HStack {
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
                Text("\(model.shots)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)

            Spacer()

            switch model.phase {
            case .countdown(let seconds):
                Text("\(seconds)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
            case .spinning:
                ZStack {
                    Circle().stroke(.white.opacity(0.25), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: model.progress)
                        .stroke(.green, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                }
                .frame(width: 160, height: 160)
                .animation(.linear(duration: 0.4), value: model.progress)
            default:
                EmptyView()
            }

            Spacer()

            bottomPanel
        }
        .padding()
    }

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .setup:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Phone on a tripod at chest height, about 1–1.5 m from a swivel chair.", systemImage: "camera")
                    Label("Sit up straight, hands resting on your legs. Keep your head still.", systemImage: "chair")
                    Label("After you tap Start you get \(model.plan.countdown) seconds to sit down. Listen for the voice.", systemImage: "speaker.wave.2")
                }
                .font(.callout)
                .foregroundStyle(.white)
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                Picker("Spin length", selection: $model.plan.spinDuration) {
                    ForEach(SpinPlan.durations, id: \.self) { seconds in
                        Text("\(Int(seconds)) s turn").tag(seconds)
                    }
                }
                .pickerStyle(.segmented)

                Button("Start") { runPass(1) }
                    .buttonStyle(.borderedProminent)

            case .betweenSpins:
                Text("Spin done. For the top of the head, raise the phone about 30 cm and tilt it down, then spin again. Or finish now.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                HStack(spacing: 12) {
                    if model.passesDone < 2 {
                        Button("Spin Again (Raised)") { runPass(2) }
                            .buttonStyle(.bordered)
                    }
                    Button("Finish") { engine?.finish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.shots < SpinCaptureModel.minimumShots)
                }

            case .countdown, .spinning:
                Text("Turn slowly and smoothly. Photos are taken automatically.")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                Button("Stop", role: .destructive) { stopPass() }
                    .buttonStyle(.bordered)

            default:
                EmptyView()
            }
        }
        .controlSize(.large)
    }

    // MARK: - Timeline

    /// Countdown → spin with spoken cues → stop.
    private func runPass(_ pass: Int) {
        let plan = model.plan
        timeline?.cancel()
        timeline = Task { @MainActor in
            voice?.say(pass == 1 ? "Get seated and face the phone." : "Sit back down and face the phone.")
            for seconds in stride(from: plan.countdown, through: 1, by: -1) {
                model.phase = .countdown(seconds)
                if seconds <= 3 { voice?.say("\(seconds)") }
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }

            model.phase = .spinning(pass: pass)
            model.progress = 0
            engine?.startShooting(pass: pass, plan: plan)
            let start = ContinuousClock.now
            for cue in plan.cues {
                let target = start + .milliseconds(Int(cue.time * 1000))
                try? await Task.sleep(until: target)
                if Task.isCancelled { return }
                voice?.say(cue.text)
            }
            engine?.stopShooting()
            model.progress = 1
            model.passesDone = pass
            model.phase = .betweenSpins
        }
    }

    private func stopPass() {
        timeline?.cancel()
        engine?.stopShooting()
        voice?.say("Stopped.")
        model.passesDone = max(model.passesDone, 1)
        model.phase = .betweenSpins
    }

    // MARK: - Lifecycle

    private func setUp() {
        guard engine == nil else { return }
        do {
            let newEngine = try SpinCaptureEngine(folder: folder, model: model)
            engine = newEngine
            voice = VoiceGuide()
            newEngine.start()
        } catch {
            model.phase = .failed("Couldn't prepare storage: \(error.localizedDescription)")
        }
    }

    private func tearDown() {
        timeline?.cancel()
        voice?.stop()
        engine?.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func finish(_ outcome: ObjectCaptureFlowView.Outcome) {
        guard !didFinish else { return }
        didFinish = true
        tearDown()
        onFinish(outcome)
    }
}

/// Live camera picture for an AVCaptureSession.
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
