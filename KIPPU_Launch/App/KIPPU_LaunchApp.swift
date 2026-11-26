import SwiftUI

@main
struct KIPPU_LaunchApp: App {
    @State private var downloads = DownloadCenter()
    @State private var backgrounds: LauncherBackgrounds
    @State private var library: InstanceLibrary

    init() {
        let appearance = LauncherBackgrounds()
        _backgrounds = State(initialValue: appearance)
        _library = State(initialValue: InstanceLibrary(didRemoveInstances: appearance.removeOverrides))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .environment(downloads)
                .environment(backgrounds)
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 620)
    }
}
