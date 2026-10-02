import AppKit
import SwiftUI

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup("ABView") {
            ContentView()
        }
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Fermer la fenêtre") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .control)
            }
        }
    }
}
