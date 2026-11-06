import SwiftData
import SwiftUI

@main
struct L23DApp: App {
    private let container: ModelContainer
    @State private var reconstruction: ReconstructionCenter

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Scan.self)
        } catch {
            fatalError("Couldn't open the scan library: \(error)")
        }
        self.container = container
        _reconstruction = State(initialValue: ReconstructionCenter(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(reconstruction)
        }
        .modelContainer(container)
    }
}
