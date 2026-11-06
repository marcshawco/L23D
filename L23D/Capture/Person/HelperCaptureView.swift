import ARKit
import RealityKit
import SwiftUI

/// Full-screen capture for "a helper walks around a still person".
struct HelperCaptureView: View {
    let folder: ScanFolder
    let onFinish: (ObjectCaptureFlowView.Outcome) -> Void

    @State private var model = HelperCaptureModel()
    @State private var arView: ARView?
    @State private var engine: HelperCaptureEngine?
    @State private var confirmCancel = false
    @State private var didFinish = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let arView {
                ARViewContainer(view: arView).ignoresSafeArea()
            }

            switch model.phase {
            case .failed(let message):
                CaptureErrorView(message: message) { finish(.cancelled) }
            case .saving, .done:
                ProgressView("Saving photos…").tint(.white).foregroundStyle(.white)
            default:
                overlay
            }
        }
        .statusBarHidden()
        .task { setUp() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            engine?.stop()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: model.phase) { _, phase in
            guard case .done(let count) = phase else { return }
            if count < HelperCaptureModel.minimumShots / 2 {
                model.phase = .failed("Only \(count) usable photos were saved. Try again with more light, and walk slowly all the way around.")
            } else {
                finish(.completed(imageCount: count))
            }
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { finish(.cancelled) }
            Button("Keep scanning", role: .cancel) {}
        }
    }

    private var overlay: some View {
        VStack {
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
                if let hint = model.hint {
                    Text(hint)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                Text("\(model.shots)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .foregroundStyle(.white)

            Spacer()

            if model.phase == .aiming || model.phase == .starting {
                // Aim point: the middle of the screen sets the person's position.
                Circle()
                    .stroke(model.canStart ? Color.green : Color.white, lineWidth: 3)
                    .frame(width: 44, height: 44)
                Spacer()
            }

            VStack(spacing: 14) {
                if model.phase == .capturing {
                    CoverageRingView(cells: model.cells, current: model.currentCell)
                        .frame(width: 150, height: 150)
                }

                Text(instruction)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                switch model.phase {
                case .aiming, .starting:
                    Button("Start") { engine?.beginCapture() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStart)
                case .capturing:
                    Button("Finish") { engine?.finish() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.shots < HelperCaptureModel.minimumShots)
                default:
                    EmptyView()
                }
            }
            .controlSize(.large)
        }
        .padding()
    }

    private var instruction: String {
        switch model.phase {
        case .starting, .aiming:
            "Ask the person to stand still, arms a little away from the body. Aim the circle at their chest, then tap Start."
        case .capturing:
            "Walk slowly all the way around: first at chest height, then low, then high. Photos are taken automatically."
        default:
            ""
        }
    }

    private func setUp() {
        guard engine == nil else { return }
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.renderOptions.insert(.disableMotionBlur)
        do {
            let newEngine = try HelperCaptureEngine(session: view.session, folder: folder, model: model)
            arView = view
            engine = newEngine
            newEngine.start()
        } catch {
            model.phase = .failed("Couldn't prepare storage: \(error.localizedDescription)")
        }
    }

    private func finish(_ outcome: ObjectCaptureFlowView.Outcome) {
        guard !didFinish else { return }
        didFinish = true
        engine?.stop()
        onFinish(outcome)
    }
}

private struct ARViewContainer: UIViewRepresentable {
    let view: ARView
    func makeUIView(context: Context) -> ARView { view }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// Three rings (inner = low, middle = chest height, outer = high). Green = photo taken.
struct CoverageRingView: View {
    let cells: [Bool]
    let current: Int?

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let slices = CoverageTracker.slices
            let gap = 2 * Double.pi / Double(slices) * 0.12
            for ring in 0..<CoverageTracker.rings {
                let radius = min(size.width, size.height) / 2 * (0.45 + 0.25 * CGFloat(ring))
                for slice in 0..<slices {
                    let index = ring * slices + slice
                    let start = Double(slice) / Double(slices) * 2 * .pi - .pi / 2 + gap / 2
                    let end = Double(slice + 1) / Double(slices) * 2 * .pi - .pi / 2 - gap / 2
                    var path = Path()
                    path.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
                    let color: Color = index == current ? .white : (cells[index] ? .green : .white.opacity(0.25))
                    context.stroke(path, with: .color(color), lineWidth: 9)
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityLabel("Coverage: \(cells.filter { $0 }.count) of \(cells.count) spots captured")
    }
}
