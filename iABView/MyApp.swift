import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct MyApp: App {
    #if os(macOS)
    init() {
        let iconURL = Bundle.main.url(
            forResource: "AppIcon-1024",
            withExtension: "png",
            subdirectory: "AppIcons"
        ) ?? Bundle.main.url(forResource: "AppIcon-1024", withExtension: "png")
        if let iconURL, let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    #endif

    var body: some Scene {
        WindowGroup("ABView") {
            ContentView()
        }
        #if os(macOS)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Fermer la fenêtre") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .control)
            }
        }
        #endif
    }
}
