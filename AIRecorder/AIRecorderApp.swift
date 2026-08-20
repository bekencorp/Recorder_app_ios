import SwiftUI

@main
struct AIRecorderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .tint(Color("AccentColor"))
        }
    }
}
