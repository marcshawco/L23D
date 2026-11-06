import Foundation

/// How a scan was (or will be) captured.
enum ScanMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A still object, using Apple's guided Object Capture.
    case object
    /// A still person; a helper walks around them with the phone.
    case personHelper
    /// A person turning on a swivel chair; phone on a tripod.
    case personSpin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .object: "Object"
        case .personHelper: "Person — Helper"
        case .personSpin: "Person — Spin Chair"
        }
    }

    var subtitle: String {
        switch self {
        case .object: "Walk around a still object on a table or floor."
        case .personHelper: "Someone stands still while a helper walks around them."
        case .personSpin: "Phone on a tripod. You turn slowly on a swivel chair."
        }
    }

    var systemImage: String {
        switch self {
        case .object: "cube"
        case .personHelper: "figure.stand"
        case .personSpin: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    /// Spin-chair mode is built in a later phase (see roadmap).
    var isAvailable: Bool {
        self != .personSpin
    }
}

/// Where a scan is in its life.
enum ScanStatus: String, Codable, Sendable {
    /// Photos are being taken.
    case capturing
    /// Photos are saved; the model has not been built yet.
    case captured
    /// The 3D model is being built.
    case processing
    /// The 3D model is ready.
    case ready
    /// Capture or processing failed.
    case failed

    var label: String {
        switch self {
        case .capturing: "Capturing"
        case .captured: "Ready to build"
        case .processing: "Building"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }
}
