import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ABVCreatorProcessRegistry.terminateAll()
        return .terminateNow
    }
}
#endif

#if os(iOS)
@MainActor
enum AppOrientationController {
    static var supportedOrientations: UIInterfaceOrientationMask = .all

    static func request(_ orientations: UIInterfaceOrientationMask) {
        supportedOrientations = orientations

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }

        windowScene.keyWindow?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations))
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone
            ? AppOrientationController.supportedOrientations
            : .all
    }
}
#endif

@main
struct MyApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

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
        #if os(macOS)
        WindowGroup("ABView", id: "abview", for: URL.self) { $bundleURL in
            ContentView(initialBundleURL: bundleURL)
        }
        .commands {
            ABVCreatorCommands()
            CommandGroup(after: .windowArrangement) {
                Button("Fermer la fenêtre") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut("w", modifiers: .control)
            }
        }

        Window("Créer un fichier ABV", id: "abv-creator") {
            ABVCreatorView()
        }
        .defaultSize(width: 820, height: 650)
        #else
        WindowGroup("ABView") {
            ContentView()
        }
        #endif
    }
}

#if os(macOS)
struct ABVCreatorCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Créer un fichier ABV…") {
                openWindow(id: "abv-creator")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
#endif
