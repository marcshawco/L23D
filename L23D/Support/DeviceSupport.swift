import ARKit
import RealityKit
import SwiftUI

/// Answers "can this device scan?" in one place.
///
/// Scanning needs a LiDAR iPhone (12 Pro or newer Pro). Everything else in the app
/// (library, viewer, export) still works on other devices and in the Simulator.
@MainActor
enum DeviceSupport {
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// LiDAR depth is available (sceneDepth only exists on LiDAR devices).
    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// Apple's guided Object Capture works on this device.
    static var supportsObjectCapture: Bool {
        ObjectCaptureSession.isSupported
    }

    /// Apple's photogrammetry (photos → 3D model) works on this device.
    static var supportsReconstruction: Bool {
        PhotogrammetrySession.isSupported
    }

    /// True when the device can capture and build models.
    static var canScan: Bool {
        !isSimulator && hasLiDAR && supportsObjectCapture && supportsReconstruction
    }

    /// Short plain-English reason scanning is not available, or nil if it is.
    static var unsupportedReason: String? {
        if isSimulator {
            return "Scanning needs a real iPhone with LiDAR. The Simulator can show the library, viewer and export only."
        }
        if !hasLiDAR {
            return "This iPhone has no LiDAR scanner. Scanning needs an iPhone 12 Pro or newer Pro model."
        }
        if !supportsObjectCapture || !supportsReconstruction {
            return "This device can't run Apple's 3D capture. Try a newer iPhone Pro."
        }
        return nil
    }
}

extension Bundle {
    /// "0.1.0 (1)"
    var versionString: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
