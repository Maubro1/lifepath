import SwiftUI

@main
struct LifePathApp: App {
    init() {
        // Stage 0 proof: this count must keep rising across updates and SideStore refreshes.
        let key = "pipeline.launchCount"
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
    }

    var body: some Scene {
        WindowGroup { PipelineView() }
    }
}
