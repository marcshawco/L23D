import SwiftData
import SwiftUI

/// Top-level screen. The library is the home of the app.
struct RootView: View {
    var body: some View {
        LibraryView()
    }
}

#Preview {
    let container = try! ModelContainer(for: Scan.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    RootView()
        .environment(ReconstructionCenter(container: container))
        .modelContainer(container)
}
