import SwiftUI

/// Top-level screen. The library is the home of the app.
struct RootView: View {
    var body: some View {
        LibraryView()
    }
}

#Preview {
    RootView()
        .modelContainer(for: Scan.self, inMemory: true)
}
