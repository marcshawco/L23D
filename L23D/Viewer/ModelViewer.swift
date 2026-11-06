import RealityKit
import SwiftUI

/// Spins a 3D model with one finger, zooms with two. Works in the Simulator too.
struct ModelViewer: View {
    let url: URL

    @State private var loadError: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.20), Color(white: 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )

            RealityView { content in
                content.camera = .virtual
                content.environment = .default
                do {
                    let model = try await Entity(contentsOf: url)
                    let root = Self.framed(model)
                    content.add(root)
                    content.add(Self.lights())
                    content.cameraTarget = root
                } catch {
                    loadError = "Couldn't open the model: \(error.localizedDescription)"
                }
            }
            .realityViewCameraControls(.orbit)

            if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
    }

    /// Centers the model at the origin and scales it to about 0.5 m across,
    /// so every scan opens at a comfortable size.
    static func framed(_ model: Entity) -> Entity {
        let bounds = model.visualBounds(relativeTo: nil)
        let largest = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        let root = Entity()
        model.position -= bounds.center
        root.addChild(model)
        if largest > 0 {
            root.scale = SIMD3(repeating: 0.5 / largest)
        }
        return root
    }

    static func lights() -> Entity {
        let rig = Entity()
        let key = DirectionalLight()
        key.light.intensity = 2500
        key.look(at: .zero, from: [0.6, 1.0, 0.8], relativeTo: nil)
        let fill = DirectionalLight()
        fill.light.intensity = 900
        fill.look(at: .zero, from: [-0.8, 0.3, -0.6], relativeTo: nil)
        rig.addChild(key)
        rig.addChild(fill)
        return rig
    }
}
