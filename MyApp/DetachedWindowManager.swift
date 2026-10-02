import AppKit
import SwiftUI

@MainActor
final class DetachedWindowManager {
    private var controllers: [String: NSWindowController] = [:]
    private var delegates: [String: WindowCloseObserver] = [:]

    func showFrontVideo(model: FlightViewModel) {
        show(
            id: "front-video",
            title: "ABView — Caméra avant",
            size: NSSize(width: 960, height: 540)
        ) {
            DetachedVideoView(model: model, isFront: true)
                .padding(8)
        }
    }

    func showBackVideo(model: FlightViewModel) {
        show(
            id: "back-video",
            title: "ABView — Caméra arrière",
            size: NSSize(width: 960, height: 540)
        ) {
            DetachedVideoView(model: model, isFront: false)
                .padding(8)
        }
    }

    func showAircraft(model: FlightViewModel) {
        show(
            id: "aircraft-3d",
            title: "ABView — Vue 3D",
            size: NSSize(width: 800, height: 700)
        ) {
            DetachedAircraftView(model: model)
        }
    }

    func showGPS(model: FlightViewModel) {
        show(
            id: "gps",
            title: "ABView — Trajectoire GPS",
            size: NSSize(width: 900, height: 700)
        ) {
            DetachedGPSView(model: model)
        }
    }

    func closeAll() {
        for controller in controllers.values {
            controller.close()
        }
        controllers.removeAll()
        delegates.removeAll()
    }

    private func show<Content: View>(
        id: String,
        title: String,
        size: NSSize,
        @ViewBuilder content: () -> Content
    ) {
        if let window = controllers[id]?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content())
        window.setFrameAutosaveName("ABView.\(id)")
        window.center()

        let observer = WindowCloseObserver { [weak self] in
            self?.controllers[id] = nil
            self?.delegates[id] = nil
        }
        window.delegate = observer

        let controller = NSWindowController(window: window)
        controllers[id] = controller
        delegates[id] = observer
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

struct DetachedVideoView: View {
    let model: FlightViewModel
    let isFront: Bool

    var body: some View {
        VideoPane(
            title: isFront ? "Caméra avant" : "Caméra arrière",
            player: isFront ? model.displayedFrontPlayer : model.displayedBackPlayer,
            timestamp: model.currentSample?.timestamp,
            elapsedTime: model.currentTime,
            previousBookmark: model.previousBookmarkName,
            upcomingBookmark: model.upcomingBookmarkName,
            flightSample: model.currentSample,
            showsFlightData: isFront,
            mountingPitch: model.mountingPitch,
            isCameraInverted: model.isCameraInverted
        )
    }
}

struct DetachedAircraftView: View {
    let model: FlightViewModel

    var body: some View {
        Aircraft3DView(
            quaternionW: model.currentSample?.quaternionW ?? 1,
            quaternionX: model.currentSample?.quaternionX ?? 0,
            quaternionY: model.currentSample?.quaternionY ?? 0,
            quaternionZ: model.currentSample?.quaternionZ ?? 0,
            modelURL: model.aircraftModelURL,
            mountingPitch: model.mountingPitch,
            isInverted: model.isCameraInverted,
            showsAxes: model.shows3DAxes,
            showsVerticalGrid: model.showsVerticalGrid,
            accelerationX: model.currentSample?.accelerationX ?? 0,
            accelerationY: model.currentSample?.accelerationY ?? 0,
            accelerationZ: model.currentSample?.accelerationZ ?? 0,
            speed: model.currentSample?.speed ?? 0
        )
        .overlay(alignment: .topLeading) {
            if let sample = model.currentSample {
                Text(
                    verbatim: String(
                        format: "%.0f km/h · %.0f ft",
                        sample.speed,
                        sample.altitude
                    )
                )
                .font(.body.monospacedDigit())
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding()
            }
        }
    }
}

struct DetachedGPSView: View {
    let model: FlightViewModel

    var body: some View {
        FlightPath3DView(model: model)
            .padding(8)
    }
}
