import SwiftUI

@main
struct CanvaARApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(CanvaAPIService.shared)
        }
    }
}
