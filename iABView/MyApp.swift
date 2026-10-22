import SwiftUI
import Observation
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

// Sums per-thread CPU usage for this process via Mach APIs, the same technique
// Activity Monitor's %CPU is derived from — one core fully busy reads 100%, so
// totals above 100% across several busy threads are expected, not a bug.
// Surfaced in the title bar as a live diagnostic while tracking down UI lag.
@MainActor
@Observable
final class CPUMonitor {
    private(set) var usageText: String = ""
    private nonisolated(unsafe) var pollingTask: Task<Void, Never>?

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                let usage = Self.currentProcessCPUUsage()
                self?.usageText = String(format: "CPU %.0f%%", usage)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    deinit {
        pollingTask?.cancel()
    }

    private static func currentProcessCPUUsage() -> Double {
        var threadsList: thread_act_array_t?
        var threadsCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadsList, &threadsCount) == KERN_SUCCESS,
              let threadsList else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: threadsList)),
                vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride)
            )
        }

        var totalPercent: Double = 0
        for index in 0..<Int(threadsCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threadsList[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            totalPercent += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return totalPercent
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
