import SwiftUI

/// Short, practical advice for each scan mode and for using exports.
struct TipsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    tip("sun.max", "Even, bright light. No harsh shadows or direct sun.")
                    tip("figure.walk", "Move slowly. The app skips blurry photos.")
                    tip("iphone.gen3", "Keep the whole subject in view the entire time.")
                    tip("thermometer.medium", "If your iPhone gets hot, let it cool. Heat slows building down.")
                } header: {
                    Text("Every scan")
                }

                Section {
                    tip("square.dashed", "Plain surface with space all around the object.")
                    tip("arrow.up.and.down", "Do 3 laps: low, middle and high — or flip the object to get its bottom.")
                    tip("sparkles", "Shiny, see-through or very thin things scan poorly. Matte is best.")
                } header: {
                    Label("Object", systemImage: ScanMode.object.systemImage)
                }

                Section {
                    tip("figure.stand", "The person stands very still, arms slightly away from the body, eyes on one spot.")
                    tip("scope", "Aim the circle at their chest, tap Start, then walk all the way around.")
                    tip("circle.dotted", "Fill the rings: chest height first, then crouch low, then hold the phone high.")
                    tip("tshirt", "Matte, fitted clothes work best. Hair is hard to capture.")
                } header: {
                    Label("Person — Helper", systemImage: ScanMode.personHelper.systemImage)
                }

                Section {
                    tip("camera", "Tripod at chest height, 1–1.5 m from a swivel chair. Back camera facing the chair.")
                    tip("speaker.wave.2", "Turn the volume up — the phone tells you when to start and stop.")
                    tip("arrow.trianglehead.2.clockwise.rotate.90", "Turn with your feet. Keep your head and shoulders still.")
                    tip("arrow.up", "Do a second, raised spin to capture the top of your head.")
                } header: {
                    Label("Person — Spin Chair", systemImage: ScanMode.personSpin.systemImage)
                }

                Section {
                    tip("shippingbox", "GLB works in Blender, Unity (glTFast), Godot and Unreal.")
                    tip("arrow.down.to.line", "\"Bottom center\" puts the model on the ground at 0,0,0 — best for games.")
                    tip("triangle", "Use Low or Very low detail for mobile games and background props.")
                } header: {
                    Text("Exporting")
                }
            }
            .navigationTitle("Scanning Tips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func tip(_ icon: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: icon).foregroundStyle(.tint)
        }
    }
}

#Preview {
    TipsView()
}
