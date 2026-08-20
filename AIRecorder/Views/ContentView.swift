import SwiftUI

struct ContentView: View {
    private enum Tab: String, Hashable {
        case library
        case device
    }

    @State private var selectedTab: Tab
    @EnvironmentObject private var model: AppModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let requestedTab = arguments.firstIndex(of: "--initial-tab")
            .flatMap { index in arguments.indices.contains(index + 1) ? arguments[index + 1] : nil }
            .flatMap(Tab.init(rawValue:))
        _selectedTab = State(initialValue: requestedTab ?? .device)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DeviceView(bluetooth: model.bluetooth)
                .tag(Tab.device)
                .tabItem {
                    Label("Device", systemImage: "dot.radiowaves.left.and.right")
                }

            LibraryView(recordings: model.recordings)
                .tag(Tab.library)
                .tabItem {
                    Label("Recordings", systemImage: "waveform")
                }
        }
    }
}
