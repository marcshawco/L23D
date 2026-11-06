import SwiftUI
import SwiftData

@main
struct L23DApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: Scan.self)
    }
}
