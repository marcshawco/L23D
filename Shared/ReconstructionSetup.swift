import Foundation
import RealityKit

/// One place that decides how a scan folder is fed to `PhotogrammetrySession`,
/// so the iPhone and the Mac build the same way (only the detail level differs).
enum ReconstructionSetup {
    static func makeSession(for folder: ScanFolder, detail: HQDetail? = nil) throws -> PhotogrammetrySession {
        var configuration = PhotogrammetrySession.Configuration()
        #if os(macOS)
        if let spec = detail?.customSpecification {
            configuration.customDetailSpecification = spec
        }
        #endif
        configuration.checkpointDirectory = folder.checkpoint
        // Every capture mode saves photos in the order they were taken.
        configuration.sampleOrdering = .sequential
        configuration.isObjectMaskingEnabled = true

        guard folder.isPersonScan else {
            return try PhotogrammetrySession(input: folder.images, configuration: configuration)
        }
        // People: photos + person masks + LiDAR depth, fed one at a time.
        // Skin and clothes have little texture, so look harder for features.
        configuration.featureSensitivity = .high
        configuration.ignoreBoundingBox = true
        let manifest = try PersonFrameStore.loadManifest(from: folder)
        let samples = PersonSampleSequence(
            folder: folder, manifest: manifest,
            limit: PhotogrammetrySession.limits.maximumNumberOfInputImages
        )
        return try PhotogrammetrySession(input: samples, configuration: configuration)
    }

    static func label(for stage: PhotogrammetrySession.Output.ProcessingStage) -> String {
        switch stage {
        case .preProcessing: "Preparing photos"
        case .imageAlignment: "Lining up photos"
        case .pointCloudGeneration: "Building point cloud"
        case .meshGeneration: "Building mesh"
        case .textureMapping: "Painting textures"
        case .optimization: "Optimizing"
        @unknown default: "Working"
        }
    }
}
