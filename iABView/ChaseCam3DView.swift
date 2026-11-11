import AVFoundation
import MapKit
import SceneKit
import simd
import SwiftUI
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
private typealias PlatformImage = NSImage
private typealias PlatformViewRepresentable = NSViewRepresentable
private typealias PlatformPanRecognizer = NSPanGestureRecognizer
private typealias PlatformGestureDelegate = NSGestureRecognizerDelegate

/// SCNView qui transmet la molette au coordinator quand il la veut (zoom pendant le glisser).
private final class ChaseSCNView: SCNView {
    var onScroll: ((Float) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.004 : 0.04
        if onScroll?(Float(event.scrollingDeltaY * scale)) != true {
            super.scrollWheel(with: event)
        }
    }
}
#else
import UIKit
private typealias PlatformColor = UIColor
private typealias PlatformImage = UIImage
private typealias PlatformViewRepresentable = UIViewRepresentable
private typealias PlatformPanRecognizer = UIPanGestureRecognizer
private typealias PlatformGestureDelegate = UIGestureRecognizerDelegate
#endif

/// Cadrages disponibles pour la caméra de poursuite 3D.
enum ChaseCam3DPreset: String, CaseIterable, Identifiable {
    /// La caméra réagit au vecteur vitesse : elle s'éloigne et élargit le champ avec la vitesse,
    /// se déporte à l'extérieur des virages et subit l'inertie des accélérations.
    case dynamic = "Dynamique"
    case close = "Proche"
    case standard = "Standard"
    case wide = "Large"
    case side = "Côté"
    case top = "Dessus"
    /// Caméra solidaire de l'avion, au bout de l'aile gauche, tournée vers le cockpit.
    case wingtip = "Bout d'aile"
    /// Caméra solidaire de l'avion, en haut de la dérive, tournée vers l'avant.
    case tail = "Empennage"

    var id: String { rawValue }

    /// Cadrage rigidement lié à l'avion (il en suit tous les mouvements, sans lissage).
    var isFixedToAircraft: Bool { self == .wingtip || self == .tail }

    /// Distance caméra-avion, en mètres.
    var distance: Float {
        switch self {
        case .dynamic: 32
        case .close: 22
        case .standard: 40
        case .wide: 90
        case .side: 45
        case .top: 70
        case .wingtip, .tail: 0
        }
    }

    /// Élévation de la caméra au-dessus de l'avion, en radians.
    var elevation: Float {
        let degrees: Float = switch self {
        case .dynamic: 14
        case .close: 12
        case .standard: 18
        case .wide: 25
        case .side: 8
        case .top: 70
        case .wingtip, .tail: 0
        }
        return degrees * .pi / 180
    }

    /// Décalage d'azimut par rapport à l'arrière de la trajectoire, en radians.
    var azimuth: Float {
        self == .side ? .pi / 2 : 0
    }
}

private func smoothstep(_ x: Float, _ low: Float, _ high: Float) -> Float {
    let t = max(0, min(1, (x - low) / (high - low)))
    return t * t * (3 - 2 * t)
}

private func wrapAngle(_ angle: Float) -> Float {
    var wrapped = angle.truncatingRemainder(dividingBy: 2 * .pi)
    if wrapped > .pi { wrapped -= 2 * .pi }
    if wrapped < -.pi { wrapped += 2 * .pi }
    return wrapped
}

/// Le décalage entre le yaw des gyros et le nord est quasi constant : un filtre complémentaire
/// l'estime quand l'azimut du nez est une mesure fiable (nez proche de l'horizontale, vol
/// stabilisé) et le gèle sinon (boucles, figures). `now` est une horloge quelconque en secondes
/// (uptime en direct, temps du vol pour un calcul hors ligne).
private struct HeadingEstimator {
    private let timeConstant: Float = 3
    private(set) var correction: Float = 0
    /// Confiance (0…1) de la dernière mesure d'azimut ; au-delà de 0,5 la valeur sert d'ancre.
    private(set) var lastWeight: Float = 0
    private var isSeeded = false
    private var hasEstimate = false
    private var lastTime: TimeInterval?
    private var previousForward: SIMD3<Float>?

    mutating func reset() {
        lastTime = nil
        isSeeded = false
        previousForward = nil
    }

    mutating func update(
        forward: SIMD3<Float>,
        up: SIMD3<Float>,
        heading: Double,
        speed: Double,
        loadFactor: Double,
        now: TimeInterval
    ) {
        let dt = lastTime.map { Float(now - $0) }
        defer {
            lastTime = now
            previousForward = forward
        }

        let horizontal = simd_length(SIMD2<Float>(forward.x, forward.z))
        var weight = smoothstep(horizontal, 0.64, 0.82)
        weight *= smoothstep(Float(speed), 30, 60)
        weight *= 1 - smoothstep(Float(abs(loadFactor - 1)), 0.25, 0.7)
        weight *= smoothstep(abs(up.y), 0.5, 0.8)
        if let dt, dt > 0, dt < 1, let previous = previousForward {
            let angle = acos(max(-1, min(1, simd_dot(previous, forward))))
            weight *= 1 - smoothstep(angle / dt, 0.5, 1.5)
        }
        lastWeight = weight
        guard horizontal > 0.05 else { return }
        let target = atan2(forward.x, -forward.z) - Float(heading * .pi / 180)

        guard isSeeded else {
            if weight > 0.5 {
                correction = target
                isSeeded = true
                hasEstimate = true
            } else if !hasEstimate {
                correction = target
            }
            return
        }
        guard weight > 0 else { return }
        guard let dt, dt < 1 else {
            if weight > 0.5 { correction = target }
            return
        }
        correction += wrapAngle(target - correction) * weight * (1 - exp(-dt / timeConstant))
    }
}

/// Options de la chase cam 3D incrustée, modifiables par son menu contextuel (clic droit).
struct ChaseCam3DOptions: Equatable {
    var preset: ChaseCam3DPreset = .close
    var showsFullPath = false
    var showsSatellite = true
    var smoothsGPS = true
}

/// Deuxième chase cam : l'avion STL (attitude, cap absolu, traînée) évolue à sa position GPS 3D
/// réelle, au milieu de la trajectoire complète, filmé par une caméra de poursuite dynamique.
struct ChaseCam3DView: View {
    let model: FlightViewModel
    /// Version incrustée (petit format) : sans contrôles ni HUD, rendue à 30 fps avec une mosaïque
    /// satellite allégée. Ses options viennent de `insetOptions` (menu clic droit de l'incrustation).
    var isInset = false
    var insetOptions = ChaseCam3DOptions()
    /// Charge aussi les tuiles satellite haute résolution à basse altitude (sinon réservées à la version fenêtrée).
    var loadsDetailTiles = false
    /// Active la souris (orbite au glisser, zoom à la molette) sur une version incrustée.
    var isInteractive = false
    @Environment(\.dismiss) private var dismiss
    @State private var preset: ChaseCam3DPreset = .standard
    @State private var showsFullPath = false
    @State private var showsSatellite = true
    @State private var smoothsGPS = true
    #if os(macOS)
    @State private var recorder = ScreenRecorder()
    @State private var hostWindow: NSWindow?
    #endif

    var body: some View {
        ChaseCam3DScene(
            samples: model.samples,
            samplesRevision: model.samplesRevision,
            player: model.frontPlayer,
            modelURL: model.aircraftModelURL,
            mountingPitch: model.mountingPitch,
            isInverted: model.isCameraInverted,
            preset: isInset ? insetOptions.preset : preset,
            showsFullPath: isInset ? insetOptions.showsFullPath : showsFullPath,
            showsSatellite: isInset ? insetOptions.showsSatellite : showsSatellite,
            smoothsGPS: isInset ? insetOptions.smoothsGPS : smoothsGPS,
            isInset: isInset,
            loadsDetailTiles: !isInset || loadsDetailTiles,
            isInteractive: !isInset || isInteractive,
            isPlaying: model.isPlaying,
            // Lu seulement en pause : un déplacement du curseur réveille alors le rendu.
            pausedTime: model.isPlaying ? 0 : model.slowTime
        )
        .overlay(alignment: .topLeading) {
            if !isInset {
                ChaseCam3DHUD(model: model)
                    .padding()
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if !isInset { controls.padding() }
        }
        .overlay(alignment: .bottom) {
            if !isInset {
                ChaseCam3DTimeline(model: model)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(WindowReader(window: $hostWindow))
        .alert(
            "Erreur d’enregistrement",
            isPresented: Binding(
                get: { recorder.errorMessage != nil },
                set: { if !$0 { recorder.dismissError() } }
            )
        ) {
            Button("OK") { recorder.dismissError() }
        } message: {
            Text(recorder.errorMessage ?? "")
        }
        #endif
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            #if !os(macOS)
            // Sur macOS la vue vit dans une fenêtre détachée, fermée par ses boutons de fenêtre.
            Button("Fermer", systemImage: "xmark.circle.fill") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            #endif
            Picker("Cadrage", selection: $preset) {
                ForEach(ChaseCam3DPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Toggle("Trajectoire complète", isOn: $showsFullPath)
                .toggleStyle(.switch)
                .fixedSize()
            Toggle("Vue satellite", isOn: $showsSatellite)
                .toggleStyle(.switch)
                .fixedSize()
            Toggle("GPS Smoothing", isOn: $smoothsGPS)
                .toggleStyle(.switch)
                .fixedSize()
            #if os(macOS)
            // Enregistre cette fenêtre (sans le son de l'app) dans `chasecam_NNN.mp4` sur le Bureau.
            Button {
                recorder.toggleRecording(window: hostWindow, filePrefix: "chasecam", capturesAudio: false)
            } label: {
                Label(
                    recorder.isRecording ? "Arrêter REC" : "Capture REC",
                    systemImage: recorder.isRecording ? "stop.fill" : "record.circle"
                )
            }
            .tint(.red)
            .disabled(hostWindow == nil)
            #endif
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}

#if os(macOS)
/// Donne accès à la `NSWindow` qui héberge la vue SwiftUI (cible de la capture d'écran).
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        Task { @MainActor in
            if window !== view.window { window = view.window }
        }
    }
}
#endif

/// Curseur de lecture : lecture/pause, heure et position dans le vol (lit `slowTime`, 4 Hz).
private struct ChaseCam3DTimeline: View {
    let model: FlightViewModel

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.togglePlayback()
            } label: {
                Label(
                    model.isPlaying ? "Pause" : "Lecture",
                    systemImage: model.isPlaying ? "pause.fill" : "play.fill"
                )
                .labelStyle(.iconOnly)
                .frame(width: 22)
            }
            .keyboardShortcut(.space, modifiers: [])

            Text(model.slowTime.clockString)
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)

            BookmarkTimelineSlider(
                value: Binding(
                    get: { model.slowTime },
                    set: model.seek
                ),
                duration: model.duration,
                bookmarks: model.bookmarks,
                videoFrameRate: model.frontVideoFrameRate
            )
            // Le slider réserve 54 pt à gauche pour l'heure des autres vues ; ici elle est à côté.
            .padding(.leading, -54)
        }
        .foregroundStyle(.white)
    }
}

/// Lit `slowSample` (4 Hz) pour ne pas réévaluer la vue 3D à chaque tick de lecture.
private struct ChaseCam3DHUD: View {
    let model: FlightViewModel

    var body: some View {
        if let sample = model.slowSample {
            VStack(alignment: .leading, spacing: 4) {
                Text("CHASE CAM 3D")
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
                Text("\(sample.speed, format: .number.precision(.fractionLength(0))) km/h")
                Text("\(sample.altitude, format: .number.precision(.fractionLength(0))) ft")
                Text("Cap \(sample.heading, format: .number.precision(.fractionLength(0)))°")
                Text("\(sample.loadFactor, format: .number.precision(.fractionLength(1))) g")
            }
            .font(.body.monospacedDigit())
            .padding(10)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(.white)
        }
    }
}

private struct ChaseCam3DScene: PlatformViewRepresentable {
    let samples: [FlightSample]
    let samplesRevision: Int
    let player: AVPlayer
    let modelURL: URL?
    let mountingPitch: Double
    let isInverted: Bool
    let preset: ChaseCam3DPreset
    let showsFullPath: Bool
    let showsSatellite: Bool
    let smoothsGPS: Bool
    let isInset: Bool
    let loadsDetailTiles: Bool
    let isInteractive: Bool
    let isPlaying: Bool
    let pausedTime: TimeInterval

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    #if os(macOS)
    func makeNSView(context: Context) -> SCNView {
        makeView(context: context)
    }

    func updateNSView(_ view: SCNView, context: Context) {
        updateView(view, context: context)
    }
    #else
    func makeUIView(context: Context) -> SCNView {
        makeView(context: context)
    }

    func updateUIView(_ view: SCNView, context: Context) {
        updateView(view, context: context)
    }
    #endif

    private func makeView(context: Context) -> SCNView {
        #if os(macOS)
        let view = ChaseSCNView()
        view.onScroll = { [weak coordinator = context.coordinator] delta in
            coordinator?.handleScroll(delta) ?? false
        }
        #else
        let view = SCNView()
        #endif
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.backgroundColor = Coordinator.skyColor
        view.antialiasingMode = isInset ? .none : .multisampling2X
        // La caméra est pilotée par le coordinator (poursuite dynamique).
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.delegate = context.coordinator
        context.coordinator.sceneView = view
        if isInteractive {
            // Maintenir le bouton (ou le doigt) enfoncé fait pivoter la caméra autour de l'avion.
            #if os(macOS)
            let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
            #else
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
            #endif
            view.addGestureRecognizer(pan)
            #if !os(macOS)
            let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
            pinch.delegate = context.coordinator
            pan.delegate = context.coordinator
            view.addGestureRecognizer(pinch)
            #endif
        }
        // La caméra se lisse image par image : 60 fps pour un mouvement fluide (30 en incrustation).
        view.preferredFramesPerSecond = isInset ? 30 : 60
        view.isPlaying = true
        view.rendersContinuously = false
        updateView(view, context: context)
        return view
    }

    private func updateView(_ view: SCNView, context: Context) {
        // Réveille le rendu (arrêté après une pause) ; le coordinator le rendort une fois la caméra posée.
        if !view.isPlaying { view.isPlaying = true }
        context.coordinator.configure(
            samples: samples,
            samplesRevision: samplesRevision,
            player: player,
            modelURL: modelURL,
            mountingPitch: mountingPitch,
            isInverted: isInverted,
            preset: preset,
            showsFullPath: showsFullPath,
            showsSatellite: showsSatellite,
            smoothsGPS: smoothsGPS,
            isInset: isInset,
            loadsDetailTiles: loadsDetailTiles,
            isPlaying: isPlaying
        )
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate, PlatformGestureDelegate {
        static let skyColor = PlatformColor(red: 0.35, green: 0.48, blue: 0.60, alpha: 1)
        /// Teinte de l'horizon : celle du brouillard, pour que le lointain se fonde dans le ciel.
        static let horizonColor = PlatformColor(red: 0.74, green: 0.87, blue: 0.97, alpha: 1)

        /// Dégradé de ciel 2:1 (zénith en haut, horizon au milieu, brume sous l'horizon).
        private static func skyImage() -> CGImage? {
            let width = 1_024
            let height = 512
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            let stops: [(location: CGFloat, red: CGFloat, green: CGFloat, blue: CGFloat)] = [
                (0.00, 0.08, 0.28, 0.72), // zénith
                (0.28, 0.22, 0.52, 0.90),
                (0.46, 0.60, 0.80, 0.96),
                (0.50, 0.74, 0.87, 0.97), // horizon
                (0.56, 0.62, 0.74, 0.80), // brume sous l'horizon
                (1.00, 0.40, 0.48, 0.50),
            ]
            let components: [CGFloat] = stops.flatMap { [$0.red, $0.green, $0.blue, CGFloat(1)] }
            guard let gradient = CGGradient(
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                colorComponents: components,
                locations: stops.map(\.location),
                count: stops.count
            ) else { return nil }
            // L'origine du contexte est en bas : le zénith (location 0) est donc en haut.
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(height)),
                end: .zero,
                options: []
            )
            return context.makeImage()
        }

        let scene = SCNScene()
        let cameraNode = SCNNode()
        private let aircraft = SCNNode()
        private let modelRoot = SCNNode()
        private let fullPathNode = SCNNode()
        private let groundGrid = SCNNode()
        private let groundShadow = SCNNode()
        /// Plan texturé par une image satellite MapKit, posé au sol sous la trajectoire.
        private let satelliteNode = SCNNode()
        /// Tuiles satellite haute résolution (≈ 0,8 m/pixel) chargées autour de l'avion à basse altitude.
        private let detailNode = SCNNode()
        private let dropLine = SCNNode()
        private let centerTrail = SCNNode()
        private let leftTrail = SCNNode()
        private let rightTrail = SCNNode()
        private let trailRungs = SCNNode()

        /// 1 unité de scène = 1 m. Le modèle STL (≈ 4,2 u d'envergure) est agrandi à l'échelle réelle.
        private let modelScale: Float = 2
        private let wingHalfSpan: Float = 2.1 * 2
        private let trailDuration: TimeInterval = 15
        private let trailPointCount = 150
        private let gridSpacing: Float = 100
        /// Côté d'une tuile de détail (m), altitude sous laquelle on les charge (m), et nombre maximal conservé.
        private let detailCellSide: Double = 800
        private let detailMaxAltitude: Float = 600
        private let detailMaxTiles = 16

        private let lock = NSLock()
        private var samples: [FlightSample] = []
        private var revision = -1
        private weak var player: AVPlayer?
        private var mountingPitch = 15.0
        private var isInverted = false
        private var preset = ChaseCam3DPreset.standard
        private var currentModelURL: URL?

        // Emprise de l'image satellite : carré centré sur le vol, en mètres.
        private var satelliteCenter: CLLocationCoordinate2D?
        private var satelliteSide: Double = 0
        private var satelliteRevision = -1
        private var satelliteTask: Task<Void, Never>?
        private var hasSatelliteImage = false
        private var detailTiles: [SIMD2<Int>: SCNNode] = [:]
        private var detailFailures: [SIMD2<Int>: TimeInterval] = [:]
        private var detailTask: Task<Void, Never>?
        private var isFetchingDetail = false
        private var detailGeneration = 0
        private var lastDetailCell = SIMD2<Int>(0, 0)
        private var showsSatellite = true
        private var isInset = false
        private var loadsDetailTiles = true
        weak var sceneView: SCNView?

        // Déviation manuelle de la caméra (glisser) : azimut et élévation ajoutés au cadrage,
        // résorbés progressivement au relâchement.
        private var orbitYaw: Float = 0
        private var orbitPitch: Float = 0
        private var isDragging = false
        /// Zoom manuel (logarithme du facteur de distance), résorbé comme la déviation.
        private var orbitZoom: Float = 0
        private var isPinching = false

        /// Molette : zoome seulement pendant que le bouton est enfoncé. Renvoie `true` si l'événement est consommé.
        func handleScroll(_ delta: Float) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard isDragging else { return false }
            orbitZoom = max(-1.2, min(1.5, orbitZoom - delta))
            idleFrames = 0
            DispatchQueue.main.async { [weak self] in self?.sceneView?.isPlaying = true }
            return true
        }

        #if !os(macOS)
        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            lock.lock()
            defer { lock.unlock() }
            switch recognizer.state {
            case .began, .changed:
                isPinching = true
                // Écarter les doigts rapproche la caméra.
                orbitZoom = max(-1.2, min(1.5, orbitZoom - log(Float(recognizer.scale))))
                recognizer.scale = 1
            default:
                isPinching = false
            }
            idleFrames = 0
            DispatchQueue.main.async { [weak self] in self?.sceneView?.isPlaying = true }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }
        #endif

        @objc func handlePan(_ recognizer: PlatformPanRecognizer) {
            let translation = recognizer.translation(in: recognizer.view)
            #if os(macOS)
            let delta = SIMD2<Float>(Float(translation.x), Float(translation.y))
            recognizer.setTranslation(.zero, in: recognizer.view)
            #else
            let delta = SIMD2<Float>(Float(translation.x), -Float(translation.y))
            recognizer.setTranslation(.zero, in: recognizer.view)
            #endif
            lock.lock()
            defer { lock.unlock() }
            switch recognizer.state {
            case .began, .changed:
                isDragging = true
                // La caméra suit la souris : vers la droite → côté droit de l'avion, vers le haut → plus haut.
                orbitYaw = wrapAngle(orbitYaw - delta.x * 0.008)
                orbitPitch = max(-0.5, min(1.2, orbitPitch + delta.y * 0.006))
            default:
                isDragging = false
            }
            idleFrames = 0
            DispatchQueue.main.async { [weak self] in self?.sceneView?.isPlaying = true }
        }
        private var isPlaybackActive = true
        /// Images consécutives sans changement de temps vidéo : au-delà d'un seuil, en pause, le rendu s'arrête.
        private var idleFrames = 0

        // Repère local de la trajectoire (origine = premier échantillon) et option de lissage.
        private var referenceLatitude = 0.0
        private var referenceLongitude = 0.0
        private var referenceCosineLatitude = 1.0
        private var groundAltitudeMeters = 0.0
        private var smoothsGPS = true

        // Trajectoire GPS en mètres (X = est, Y = altitude au-dessus du point le plus bas, -Z = nord).
        // Un nœud par position GPS distincte : l'interpolation lisse les paliers des fixes GPS.
        private var knotTimes: [Double] = []
        private var knotPositions: [SIMD3<Float>] = []

        // État de la caméra et de l'estimation du cap.
        private var lastRenderTime: TimeInterval?
        private var lastPlayerSeconds: TimeInterval?
        private var lastTrailSeconds: TimeInterval = -.infinity
        private var needsCameraSnap = true
        private var chaseHeading: Float = 0
        private var chaseClimb: Float = 0
        private var hasChaseDirection = false
        private var cameraOffset = SIMD3<Float>(0, 5, 30)
        private var turnRate: Float = 0
        private var lastTargetHeading: Float = 0
        private var currentFieldOfView: Float = 60

        override init() {
            super.init()
            configureScene()
        }

        // MARK: - Configuration (thread principal)

        func configure(
            samples: [FlightSample],
            samplesRevision: Int,
            player: AVPlayer,
            modelURL: URL?,
            mountingPitch: Double,
            isInverted: Bool,
            preset: ChaseCam3DPreset,
            showsFullPath: Bool,
            showsSatellite: Bool,
            smoothsGPS: Bool,
            isInset: Bool,
            loadsDetailTiles: Bool,
            isPlaying: Bool
        ) {
            lock.lock()
            defer { lock.unlock() }
            self.isInset = isInset
            self.loadsDetailTiles = loadsDetailTiles
            self.isPlaybackActive = isPlaying
            idleFrames = 0
            self.showsSatellite = showsSatellite
            let smoothingChanged = self.smoothsGPS != smoothsGPS
            self.smoothsGPS = smoothsGPS
            self.mountingPitch = mountingPitch
            self.isInverted = isInverted
            if self.preset != preset {
                self.preset = preset
                needsCameraSnap = true
            }
            self.player = player
            fullPathNode.isHidden = !showsFullPath
            loadModelIfNeeded(from: modelURL)

            let needsRebuild = revision != samplesRevision
                || self.samples.count != samples.count
                || self.samples.first?.timestamp != samples.first?.timestamp
                || self.samples.last?.timestamp != samples.last?.timestamp
            if needsRebuild {
                revision = samplesRevision
                self.samples = samples
                rebuildWorld()
            } else if smoothingChanged {
                rebuildTrajectory()
            }
            updateSatelliteIfNeeded()
        }

        // MARK: - Vue satellite

        /// Télécharge (une fois par vol) une mosaïque de tuiles satellite autour de la trajectoire.
        ///
        /// Un instantané unique très étendu n'est pas fiable : MapKit ne charge de façon complète
        /// que les zones proches de la trajectoire. On demande donc une grille de petits instantanés,
        /// chacun à une échelle où l'imagerie est entièrement chargée, du centre vers l'extérieur,
        /// pour que le sol soit texturé jusqu'au loin dans toutes les directions.
        private func updateSatelliteIfNeeded() {
            let visible = showsSatellite && hasSatelliteImage
            satelliteNode.isHidden = !visible
            detailNode.isHidden = !showsSatellite
            groundGrid.isHidden = visible
            guard showsSatellite, satelliteRevision != revision, let center = satelliteCenter else { return }
            satelliteRevision = revision
            satelliteTask?.cancel()

            // L'incrustation, petite à l'écran, se contente d'une mosaïque allégée (≈ 9 Mo de textures).
            #if os(macOS)
            let gridSize = isInset ? 3 : 5
            #else
            let gridSize = 3
            #endif
            let pixels: CGFloat = isInset ? 512 : 1_024
            let tileSide = satelliteSide / Double(gridSize)
            let metersPerDegree = 111_320.0
            let cosineLatitude = cos(center.latitude * .pi / 180)
            let requestedRevision = revision

            // Centres des tuiles (décalages est/nord en mètres), triés du plus proche au plus lointain.
            var offsets: [(east: Double, north: Double)] = []
            for column in 0..<gridSize {
                for row in 0..<gridSize {
                    offsets.append((
                        east: (Double(column) - Double(gridSize - 1) / 2) * tileSide,
                        north: (Double(row) - Double(gridSize - 1) / 2) * tileSide
                    ))
                }
            }
            offsets.sort { hypot($0.east, $0.north) < hypot($1.east, $1.north) }

            satelliteTask = Task { [weak self] in
                for offset in offsets {
                    if Task.isCancelled { return }
                    let tileCenter = CLLocationCoordinate2D(
                        latitude: center.latitude + offset.north / metersPerDegree,
                        longitude: center.longitude + offset.east / (metersPerDegree * cosineLatitude)
                    )
                    let options = MKMapSnapshotter.Options()
                    options.region = MKCoordinateRegion(
                        center: tileCenter, latitudinalMeters: tileSide, longitudinalMeters: tileSide
                    )
                    options.mapType = .satellite
                    options.size = CGSize(width: pixels, height: pixels)
                    // Une tuile qui échoue laisse un trou, sans bloquer les suivantes.
                    guard let snapshot = try? await MKMapSnapshotter(options: options).start(),
                          !Task.isCancelled else { continue }
                    self?.addSatelliteTile(
                        snapshot.image,
                        east: offset.east,
                        north: offset.north,
                        side: tileSide,
                        forRevision: requestedRevision
                    )
                }
            }
        }

        private func addSatelliteTile(
            _ image: PlatformImage,
            east: Double,
            north: Double,
            side: Double,
            forRevision requestedRevision: Int
        ) {
            lock.lock()
            defer { lock.unlock() }
            // Le vol a changé pendant le téléchargement : l'image ne correspond plus.
            guard requestedRevision == revision else { return }
            let plane = SCNPlane(width: CGFloat(side), height: CGFloat(side))
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.diffuse.contents = image
            material.diffuse.mipFilter = .linear
            material.diffuse.minificationFilter = .linear
            material.diffuse.magnificationFilter = .linear
            material.diffuse.maxAnisotropy = 8
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            plane.materials = [material]
            // `satelliteNode` est couché à plat (x = est, y local = nord) : la tuile se place par
            // ses décalages est/nord par rapport au centre de la mosaïque.
            let tile = SCNNode(geometry: plane)
            tile.renderingOrder = -2
            tile.simdPosition = SIMD3<Float>(Float(east), Float(north), 0)
            satelliteNode.addChildNode(tile)
            hasSatelliteImage = true
            satelliteNode.isHidden = !showsSatellite
            groundGrid.isHidden = showsSatellite
        }

        // MARK: - Tuiles satellite de détail

        private func resetDetailTiles() {
            detailGeneration += 1
            detailTask?.cancel()
            isFetchingDetail = false
            detailTiles.removeAll()
            detailFailures.removeAll()
            detailNode.childNodes.forEach { $0.removeFromParentNode() }
        }

        /// Charge, à basse altitude, les tuiles 3×3 autour de l'avion sur une grille fixe de 800 m ;
        /// elles recouvrent la mosaïque générale (≈ 2 à 6 m/pixel) avec une image environ 4× plus fine.
        private func updateDetailTiles(around position: SIMD3<Float>) {
            guard loadsDetailTiles, showsSatellite, !isFetchingDetail, position.y < detailMaxAltitude,
                  abs(referenceLatitude) > 0 || abs(referenceLongitude) > 0 else { return }
            let center = SIMD2<Int>(
                Int((Double(position.x) / detailCellSide).rounded()),
                Int((Double(-position.z) / detailCellSide).rounded())
            )
            lastDetailCell = center
            let now = ProcessInfo.processInfo.systemUptime
            var cells: [SIMD2<Int>] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    let cell = SIMD2<Int>(center.x + dx, center.y + dy)
                    if detailTiles[cell] != nil { continue }
                    if let failedAt = detailFailures[cell], now - failedAt < 30 { continue }
                    cells.append(cell)
                }
            }
            guard !cells.isEmpty else { return }
            cells.sort { abs($0.x - center.x) + abs($0.y - center.y) < abs($1.x - center.x) + abs($1.y - center.y) }

            isFetchingDetail = true
            let generation = detailGeneration
            let side = detailCellSide
            let metersPerDegree = 111_320.0
            let latitude = referenceLatitude
            let longitude = referenceLongitude
            let cosineLatitude = referenceCosineLatitude
            #if os(macOS)
            let pixels: CGFloat = 1_024
            #else
            let pixels: CGFloat = 768
            #endif
            detailTask = Task { [weak self] in
                for cell in cells {
                    if Task.isCancelled { return }
                    let tileCenter = CLLocationCoordinate2D(
                        latitude: latitude + Double(cell.y) * side / metersPerDegree,
                        longitude: longitude + Double(cell.x) * side / (metersPerDegree * cosineLatitude)
                    )
                    let options = MKMapSnapshotter.Options()
                    options.region = MKCoordinateRegion(
                        center: tileCenter, latitudinalMeters: side, longitudinalMeters: side
                    )
                    options.mapType = .satellite
                    options.size = CGSize(width: pixels, height: pixels)
                    let snapshot = try? await MKMapSnapshotter(options: options).start()
                    if Task.isCancelled { return }
                    self?.finishDetailTile(snapshot?.image, cell: cell, generation: generation)
                }
                self?.finishDetailFetch(generation: generation)
            }
        }

        private func finishDetailFetch(generation: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard generation == detailGeneration else { return }
            isFetchingDetail = false
        }

        private func finishDetailTile(_ image: PlatformImage?, cell: SIMD2<Int>, generation: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard generation == detailGeneration else { return }
            guard let image else {
                detailFailures[cell] = ProcessInfo.processInfo.systemUptime
                return
            }
            let side = CGFloat(detailCellSide)
            let plane = SCNPlane(width: side, height: side)
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.diffuse.contents = image
            material.diffuse.mipFilter = .linear
            material.diffuse.minificationFilter = .linear
            material.diffuse.magnificationFilter = .linear
            material.diffuse.maxAnisotropy = 8
            material.diffuse.wrapS = .clamp
            material.diffuse.wrapT = .clamp
            // Dessinées après la mosaïque générale et par-dessus, sans test de profondeur :
            // pas de scintillement à grande distance, l'avion (ordre 0) reste devant.
            material.readsFromDepthBuffer = false
            material.writesToDepthBuffer = false
            plane.materials = [material]
            let tile = SCNNode(geometry: plane)
            tile.renderingOrder = -1
            // `detailNode` est couché à plat comme `satelliteNode` : x = est, y local = nord.
            tile.simdPosition = SIMD3<Float>(Float(Double(cell.x) * detailCellSide), Float(Double(cell.y) * detailCellSide), 0)
            detailNode.addChildNode(tile)
            detailTiles[cell] = tile
            detailFailures[cell] = nil
            // Garde les tuiles les plus proches de l'avion pour borner la mémoire.
            while detailTiles.count > detailMaxTiles {
                guard let farthest = detailTiles.keys.max(by: {
                    abs($0.x - lastDetailCell.x) + abs($0.y - lastDetailCell.y)
                        < abs($1.x - lastDetailCell.x) + abs($1.y - lastDetailCell.y)
                }) else { break }
                detailTiles[farthest]?.removeFromParentNode()
                detailTiles[farthest] = nil
            }
        }

        private func rebuildWorld() {
            knotTimes = []
            knotPositions = []
            centerTrail.geometry = nil
            leftTrail.geometry = nil
            rightTrail.geometry = nil
            trailRungs.geometry = nil
            fullPathNode.geometry = nil
            lastTrailSeconds = -.infinity
            resetHeadingEstimate()
            needsCameraSnap = true
            hasChaseDirection = false
            satelliteTask?.cancel()
            satelliteNode.childNodes.forEach { $0.removeFromParentNode() }
            resetDetailTiles()
            hasSatelliteImage = false
            satelliteRevision = -1
            satelliteCenter = nil
            guard let first = samples.first else { return }

            let metersPerDegree = 111_320.0
            let cosineLatitude = cos(first.latitude * .pi / 180)

            // Emprise satellite : carré centré sur la boîte englobante du vol, large marge pour que
            // la tuile se prolonge jusqu'à l'horizon (≈ 1,5 à 5 m/pixel selon la taille).
            let latitudes = samples.map(\.latitude)
            let longitudes = samples.map(\.longitude)
            if let minLatitude = latitudes.min(), let maxLatitude = latitudes.max(),
               let minLongitude = longitudes.min(), let maxLongitude = longitudes.max() {
                let centerLatitude = (minLatitude + maxLatitude) / 2
                let centerLongitude = (minLongitude + maxLongitude) / 2
                let eastExtent = (maxLongitude - minLongitude) * metersPerDegree * cosineLatitude
                let northExtent = (maxLatitude - minLatitude) * metersPerDegree
                // Carré couvert par la mosaïque : assez large pour garnir l'horizon (le brouillard
                // commence à 5 km), borné pour garder une résolution exploitable (≈ 2 à 6 m/pixel).
                satelliteSide = min(30_000, max(10_000, max(eastExtent, northExtent) * 3))
                satelliteCenter = CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
                // L'image est orientée nord en haut : X = est, -Z = nord dans la scène.
                let centerEast = (centerLongitude - first.longitude) * metersPerDegree * cosineLatitude
                let centerNorth = (centerLatitude - first.latitude) * metersPerDegree
                satelliteNode.simdPosition = SIMD3<Float>(Float(centerEast), 0, Float(-centerNorth))
            }
            referenceLatitude = first.latitude
            referenceLongitude = first.longitude
            referenceCosineLatitude = cosineLatitude
            groundAltitudeMeters = (samples.map(\.altitude).min() ?? 0) * 0.3048
            rebuildTrajectory()
        }

        /// Construit la trajectoire en mètres (brute, ou lissée par fusion GPS/attitude) et son tube.
        private func rebuildTrajectory() {
            knotTimes = []
            knotPositions = []
            centerTrail.geometry = nil
            leftTrail.geometry = nil
            rightTrail.geometry = nil
            trailRungs.geometry = nil
            fullPathNode.geometry = nil
            lastTrailSeconds = -.infinity
            // Force le recalcul de la traînée à la prochaine image, même en pause.
            lastPlayerSeconds = nil
            guard !samples.isEmpty else { return }

            let metersPerDegree = 111_320.0
            var rawTimes: [Double] = []
            var rawPositions: [SIMD3<Float>] = []
            var last: FlightSample?
            for sample in samples {
                if let last, last.latitude == sample.latitude,
                   last.longitude == sample.longitude, last.altitude == sample.altitude {
                    continue
                }
                let east = (sample.longitude - referenceLongitude) * metersPerDegree * referenceCosineLatitude
                let north = (sample.latitude - referenceLatitude) * metersPerDegree
                rawTimes.append(sample.elapsed)
                rawPositions.append(
                    SIMD3<Float>(
                        Float(east),
                        Float(sample.altitude * 0.3048 - groundAltitudeMeters),
                        Float(-north)
                    )
                )
                last = sample
            }
            guard rawPositions.count > 1 else { return }

            buildHeadingSeries(rawTimes: rawTimes, rawPositions: rawPositions)

            if smoothsGPS {
                let smoothed = smoothedTrajectory(rawTimes: rawTimes, rawPositions: rawPositions)
                knotTimes = smoothed.times
                knotPositions = smoothed.positions
            } else {
                knotTimes = rawTimes
                knotPositions = rawPositions
            }

            // Trajectoire complète, sous-échantillonnée, en tube coloré par la vitesse.
            let strideValue = max(1, knotPositions.count / 3_000)
            var points: [SIMD3<Float>] = []
            var colors: [SIMD4<Float>] = []
            for index in Swift.stride(from: 0, to: knotPositions.count, by: strideValue) {
                points.append(knotPositions[index])
                var color = Self.speedColor(samples[sampleIndex(at: knotTimes[index], in: samples)].speed)
                color.w = 0.6
                colors.append(color)
            }
            fullPathNode.geometry = Self.tubeGeometry(points: points, colors: colors, radius: 0.1, sides: 4)
        }

        /// Calcule, hors ligne, le décalage de cap (gyros → nord) à chaque instant du vol.
        ///
        /// L'estimateur en direct est causal et se fige pendant les figures : l'avion peut alors
        /// sembler « de travers » par rapport à la trajectoire. Ici l'azimut de référence est celui
        /// de la trajectoire affichée (vitesse sol issue des positions), et les zones sans mesure
        /// fiable sont interpolées entre l'ancre fiable qui les précède et celle qui les suit.
        private func buildHeadingSeries(rawTimes: [Double], rawPositions: [SIMD3<Float>]) {
            headingSeries = []
            let step = 0.1
            let start = rawTimes[0]
            let count = Int((rawTimes[rawTimes.count - 1] - start) / step) + 1
            guard count > 20 else { return }

            var grid: [SIMD3<Float>] = []
            grid.reserveCapacity(count)
            for index in 0..<count {
                grid.append(Self.interpolate(
                    times: rawTimes, positions: rawPositions, at: start + Double(index) * step
                ))
            }

            var estimator = HeadingEstimator()
            var corrections = [Float](repeating: 0, count: count)
            var anchors: [Int] = []
            for index in 0..<count {
                let time = start + Double(index) * step
                let sample = samples[sampleIndex(at: time, in: samples)]
                let orientation = sceneOrientation(of: sample, mountingPitch: mountingPitch, isInverted: isInverted)
                let lower = max(index - 1, 0)
                let upper = min(index + 1, count - 1)
                let velocity = grid[upper] - grid[lower]
                // Azimut de la trajectoire quand elle est définie, sinon cap GPS fourni.
                let referenceHeading = simd_length(SIMD2<Float>(velocity.x, velocity.z)) / (Float(upper - lower) * 0.1) > 5
                    ? Double(atan2(velocity.x, -velocity.z)) * 180 / .pi
                    : sample.heading
                estimator.update(
                    forward: orientation.act(SIMD3<Float>(0, 0, -1)),
                    up: orientation.act(SIMD3<Float>(0, 1, 0)),
                    heading: referenceHeading,
                    speed: sample.speed,
                    loadFactor: sample.loadFactor,
                    now: time
                )
                corrections[index] = estimator.correction
                if estimator.lastWeight > 0.5 { anchors.append(index) }
            }

            guard let firstAnchor = anchors.first, let lastAnchor = anchors.last else {
                headingSeries = corrections
                headingSeriesStart = start
                return
            }
            // Avant la première ancre et après la dernière : valeur tenue ; entre deux ancres
            // éloignées : interpolation linéaire de l'angle (par le plus court chemin).
            var series = corrections
            for index in 0..<firstAnchor { series[index] = corrections[firstAnchor] }
            if lastAnchor + 1 < count {
                for index in (lastAnchor + 1)..<count { series[index] = corrections[lastAnchor] }
            }
            for pair in zip(anchors, anchors.dropFirst()) where pair.1 - pair.0 > 1 {
                let from = corrections[pair.0]
                let delta = wrapAngle(corrections[pair.1] - from)
                for index in (pair.0 + 1)..<pair.1 {
                    series[index] = from + delta * Float(index - pair.0) / Float(pair.1 - pair.0)
                }
            }
            headingSeries = series
            headingSeriesStart = start
        }

        /// Décalage de cap à l'instant `time` : série hors ligne si elle existe, sinon estimateur en direct.
        private func headingCorrection(at time: TimeInterval) -> Float {
            guard headingSeries.count > 1 else { return headingEstimator.correction }
            let position = max(0, min(Double(headingSeries.count - 1), (time - headingSeriesStart) / 0.1))
            let lower = Int(position)
            let upper = min(lower + 1, headingSeries.count - 1)
            let fraction = Float(position - Double(lower))
            return headingSeries[lower] + wrapAngle(headingSeries[upper] - headingSeries[lower]) * fraction
        }

        /// Fusionne la trajectoire GPS avec une navigation à l'estime (attitude × vitesse).
        ///
        /// En manœuvre verticale (hammerhead, immelmann) le GPS décroche plusieurs secondes alors
        /// que l'attitude reste très bonne. Un indice de fiabilité du GPS est calculé tous les
        /// 0,1 s : cohérence entre la direction du vecteur vitesse GPS et celle du nez, accélération
        /// plausible, cohérence avec la vitesse sol mesurée. Là où il chute, la position suit
        /// l'estime ; là où il est bon, elle suit le GPS, et l'estime est recalée vers lui avec une
        /// constante de temps de 8 s au plus, pour que l'erreur n'ait pas le temps de s'accumuler.
        private func smoothedTrajectory(
            rawTimes: [Double],
            rawPositions: [SIMD3<Float>]
        ) -> (times: [Double], positions: [SIMD3<Float>]) {
            let step = 0.1
            let start = rawTimes[0]
            let count = Int((rawTimes[rawTimes.count - 1] - start) / step) + 1
            guard count > 20 else { return (rawTimes, rawPositions) }
            let dt = Float(step)

            // 1. Grille régulière : position GPS, cap du nez corrigé (cap absolu) et vitesse sol.
            var times: [Double] = []
            var grid: [SIMD3<Float>] = []
            var noses: [SIMD3<Float>] = []
            var groundSpeeds: [Float] = []
            for index in 0..<count {
                let time = start + Double(index) * step
                times.append(time)
                grid.append(Self.interpolate(times: rawTimes, positions: rawPositions, at: time))
                let sample = samples[sampleIndex(at: time, in: samples)]
                let orientation = sceneOrientation(of: sample, mountingPitch: mountingPitch, isInverted: isInverted)
                let nose = orientation.act(SIMD3<Float>(0, 0, -1))
                noses.append(yawQuaternion(headingCorrection(at: time)).act(nose))
                groundSpeeds.append(Float(sample.speed / 3.6))
            }

            // 2. Fiabilité du GPS à chaque instant.
            var gpsVelocities = [SIMD3<Float>](repeating: .zero, count: count)
            var reliability = [Float](repeating: 1, count: count)
            for index in 0..<count {
                let lower = max(index - 1, 0)
                let upper = min(index + 1, count - 1)
                let velocity = (grid[upper] - grid[lower]) / (Float(upper - lower) * dt)
                gpsVelocities[index] = velocity
                guard index >= 2, index < count - 2 else { continue }

                var score: Float = 1
                let gpsSpeed = simd_length(velocity)
                if gpsSpeed > 8 {
                    // Le vecteur vitesse GPS doit rester à peu près dans l'axe du nez.
                    let cosine = max(-1, min(1, simd_dot(velocity / gpsSpeed, noses[index])))
                    score = min(score, 1 - smoothstep(acos(cosine), 0.6, 1.2))
                }
                // Accélération irréaliste pour un avion de voltige : GPS en décrochage.
                let acceleration = (grid[index + 2] - 2 * grid[index] + grid[index - 2]) / (4 * dt * dt)
                score = min(score, 1 - smoothstep(simd_length(acceleration) / 9.80665, 5, 10))
                if groundSpeeds[index] > 10 {
                    let ratio = gpsSpeed / groundSpeeds[index]
                    score = min(score, 1 - smoothstep(abs(ratio - 1), 0.35, 0.8))
                }
                reliability[index] = score
            }
            // Élargit les zones douteuses de ±0,8 s (le GPS dérive avant et après), puis adoucit.
            var widened = reliability
            for index in 0..<count {
                var minimum: Float = 1
                for neighbor in max(0, index - 8)...min(count - 1, index + 8) {
                    minimum = min(minimum, reliability[neighbor])
                }
                widened[index] = minimum
            }
            var blurred = widened
            for index in 0..<count {
                let range = max(0, index - 5)...min(count - 1, index + 5)
                blurred[index] = range.reduce(0) { $0 + widened[$1] } / Float(range.count)
            }

            // 3. Intégration : vitesse mêlant GPS et estime, puis recalage vers le GPS d'autant plus
            // fort que celui-ci est fiable (de ≈ 0,15 s à 8 s).
            var smoothed = grid
            for index in 1..<count {
                let trust = blurred[index]
                let velocity = gpsVelocities[index] * trust + noses[index] * groundSpeeds[index] * (1 - trust)
                let predicted = smoothed[index - 1] + velocity * dt
                let timeConstant = 0.15 * pow(8 / 0.15, 1 - trust)
                smoothed[index] = predicted + (grid[index] - predicted) * (1 - exp(-dt / timeConstant))
            }
            return (times, smoothed)
        }

        // MARK: - Boucle de rendu

        func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            // Verrou tenu pendant toute l'image : la trajectoire (knots) peut être remplacée par le
            // thread principal (changement de vol ou de lissage GPS) et doit rester cohérente.
            lock.lock()
            defer { lock.unlock() }
            let samples = samples
            let player = player
            let mountingPitch = mountingPitch
            let isInverted = isInverted
            let preset = preset
            let snapRequested = needsCameraSnap
            needsCameraSnap = false

            guard let player, !samples.isEmpty, knotTimes.count > 1 else { return }
            let seconds = player.currentTime().seconds
            guard seconds.isFinite else { return }

            let wallDelta = lastRenderTime.map { Float(max(0, min(0.1, time - $0))) } ?? 0
            lastRenderTime = time

            // Saut dans la vidéo : le décalage de cap a dérivé et la caméra doit se recaler.
            var snap = snapRequested
            if let previous = lastPlayerSeconds, abs(seconds - previous) > 0.5 {
                resetHeadingEstimate()
                snap = true
            }
            let timeChanged = lastPlayerSeconds != seconds
            lastPlayerSeconds = seconds
            if timeChanged || snap || isPlaybackActive {
                idleFrames = 0
            } else {
                idleFrames += 1
                // En pause, la caméra converge en ≈ 2 s puis plus rien ne bouge : on arrête le rendu.
                if idleFrames == 150, let view = sceneView {
                    DispatchQueue.main.async { view.isPlaying = false }
                }
            }

            let index = sampleIndex(at: seconds, in: samples)
            let sample = samples[index]
            let position = worldPosition(at: seconds)
            updateDetailTiles(around: position)
            let before = worldPosition(at: seconds - 0.5)
            let after = worldPosition(at: seconds + 0.5)
            let velocity = after - before
            // Dérivée seconde de la trajectoire (m/s²) : l'accélération ressentie par l'avion.
            let acceleration = (after - 2 * position + before) / 0.25

            var orientation = sceneOrientation(of: sample, mountingPitch: mountingPitch, isInverted: isInverted)
            if timeChanged {
                let forward = orientation.act(SIMD3<Float>(0, 0, -1))
                let up = orientation.act(SIMD3<Float>(0, 1, 0))
                updateHeadingOffset(
                    forward: forward,
                    up: up,
                    heading: sample.heading,
                    speed: sample.speed,
                    loadFactor: sample.loadFactor
                )
            }
            orientation = yawQuaternion(headingCorrection(at: seconds)) * orientation

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            aircraft.simdPosition = position
            aircraft.simdOrientation = orientation
            updateGroundReferences(at: position)
            updateCamera(
                position: position,
                velocity: velocity,
                acceleration: acceleration,
                noseForward: orientation.act(SIMD3<Float>(0, 0, -1)),
                orientation: orientation,
                preset: preset,
                deltaTime: wallDelta,
                snap: snap
            )
            if timeChanged, abs(seconds - lastTrailSeconds) >= 0.1 {
                lastTrailSeconds = seconds
                updateTrail(
                    seconds: seconds,
                    samples: samples,
                    mountingPitch: mountingPitch,
                    isInverted: isInverted
                )
            }
            SCNTransaction.commit()
        }

        // MARK: - Caméra de poursuite

        private func updateCamera(
            position: SIMD3<Float>,
            velocity: SIMD3<Float>,
            acceleration: SIMD3<Float>,
            noseForward: SIMD3<Float>,
            orientation: simd_quatf,
            preset: ChaseCam3DPreset,
            deltaTime: Float,
            snap: Bool
        ) {
            // Cap et pente de la trajectoire (et non du nez) : la caméra ne tourne pas sur elle-même
            // pendant les vrilles et les tonneaux, et suit les boucles par l'arrière de la trajectoire.
            let horizontalSpeed = simd_length(SIMD2<Float>(velocity.x, velocity.z))
            let source = horizontalSpeed > 2 ? velocity : noseForward
            let sourceHorizontal = simd_length(SIMD2<Float>(source.x, source.z))
            if sourceHorizontal > 0.001 {
                let targetHeading = atan2(source.x, -source.z)
                let targetClimb = max(-0.6, min(0.6, source.y / max(0.001, simd_length(source))))
                // Taux de virage de la trajectoire (rad/s), lissé : sert au déport de la caméra.
                if snap || !hasChaseDirection || deltaTime <= 0 {
                    turnRate = 0
                } else {
                    let rate = max(-1.5, min(1.5, wrappedAngle(targetHeading - lastTargetHeading) / deltaTime))
                    turnRate += (rate - turnRate) * (1 - exp(-deltaTime / 0.5))
                }
                lastTargetHeading = targetHeading
                if snap || !hasChaseDirection {
                    chaseHeading = targetHeading
                    chaseClimb = targetClimb
                    hasChaseDirection = true
                } else {
                    let factor = 1 - exp(-deltaTime / 0.9)
                    chaseHeading += wrappedAngle(targetHeading - chaseHeading) * factor
                    chaseClimb += (targetClimb - chaseClimb) * factor
                }
            }

            if preset.isFixedToAircraft {
                updateFixedCamera(position: position, orientation: orientation, preset: preset)
                return
            }
            if let camera = cameraNode.camera, camera.zNear != 2 { camera.zNear = 2 }

            var azimuth = preset.azimuth
            var distance = preset.distance
            var inertia = SIMD3<Float>.zero
            var fieldOfView: Float = 60
            if preset == .dynamic {
                let speedRatio = min(1, simd_length(velocity) / 90)
                // Plus vite : la caméra recule et le champ s'élargit, la vitesse se « sent ».
                distance *= 1 + 0.4 * speedRatio
                fieldOfView = 58 + 10 * speedRatio
                // Virage à droite (cap qui augmente) : la caméra glisse vers l'extérieur, à gauche,
                // et montre l'inclinaison de l'avion ; inversement à gauche.
                azimuth += max(-0.5, min(0.5, turnRate * 0.6))
                // Inertie : la caméra est « tirée » à l'opposé de l'accélération (g en ressource,
                // freinage, début de virage), bornée pour rester cadrée.
                inertia = -acceleration * 0.15
                let limit = distance * 0.25
                let magnitude = simd_length(inertia)
                if magnitude > limit { inertia *= limit / magnitude }
            }
            if !isDragging && !isPinching {
                let decay = exp(-deltaTime / 0.7)
                orbitYaw *= decay
                orbitPitch *= decay
                orbitZoom *= decay
                if abs(orbitYaw) < 0.001 && abs(orbitPitch) < 0.001 && abs(orbitZoom) < 0.001 {
                    orbitYaw = 0
                    orbitPitch = 0
                    orbitZoom = 0
                }
            }
            distance *= exp(orbitZoom)
            let backHeading = chaseHeading + .pi + azimuth + orbitYaw
            let elevation = max(-0.35, min(1.5, preset.elevation + orbitPitch))
            let targetOffset = SIMD3<Float>(
                sin(backHeading) * distance * cos(elevation),
                distance * sin(elevation) - chaseClimb * distance * 0.35,
                -cos(backHeading) * distance * cos(elevation)
            ) + inertia
            if snap {
                currentFieldOfView = fieldOfView
            } else {
                currentFieldOfView += (fieldOfView - currentFieldOfView) * (1 - exp(-deltaTime / 0.6))
            }
            if let camera = cameraNode.camera, abs(Float(camera.fieldOfView) - currentFieldOfView) > 0.01 {
                camera.fieldOfView = CGFloat(currentFieldOfView)
            }
            if snap {
                cameraOffset = targetOffset
            } else {
                cameraOffset += (targetOffset - cameraOffset) * (1 - exp(-deltaTime / 0.25))
            }

            var cameraPosition = position + cameraOffset
            cameraPosition.y = max(cameraPosition.y, 3)
            let lead = SIMD3<Float>(sin(chaseHeading), 0, -cos(chaseHeading)) * distance * 0.12
            cameraNode.simdPosition = cameraPosition
            cameraNode.simdLook(
                at: position + lead,
                up: SIMD3<Float>(0, 1, 0),
                localFront: SIMD3<Float>(0, 0, -1)
            )
        }

        /// Caméra liée à l'avion : position et visée définies dans le repère de l'avion
        /// (x = droite, y = haut, -z = nez), en unités du modèle avant mise à l'échelle.
        private func updateFixedCamera(position: SIMD3<Float>, orientation: simd_quatf, preset: ChaseCam3DPreset) {
            let mount: SIMD3<Float>
            let target: SIMD3<Float>
            let fieldOfView: CGFloat
            switch preset {
            case .tail:
                // Sommet de la dérive, regard vers l'avant et légèrement vers le bas.
                mount = SIMD3<Float>(0, 1.15, 3.2)
                target = SIMD3<Float>(0, 0.1, -6)
                fieldOfView = 80
            default:
                // Au large de l'aile gauche, regard à 90° de l'axe longitudinal (pile vers la droite),
                // à la hauteur du fuselage : mêmes y et z pour la caméra et la cible.
                mount = SIMD3<Float>(-4.6, 0.1, 0)
                target = SIMD3<Float>(0, 0.1, 0)
                fieldOfView = 70
            }
            let up = orientation.act(SIMD3<Float>(0, 1, 0))
            cameraNode.simdPosition = position + orientation.act(mount * modelScale)
            cameraNode.simdLook(
                at: position + orientation.act(target * modelScale),
                up: up,
                localFront: SIMD3<Float>(0, 0, -1)
            )
            currentFieldOfView = Float(fieldOfView)
            if let camera = cameraNode.camera {
                if camera.fieldOfView != fieldOfView { camera.fieldOfView = fieldOfView }
                // Caméra très proche de la structure : plan proche rapproché.
                if camera.zNear != 0.3 { camera.zNear = 0.3 }
            }
        }

        private func wrappedAngle(_ angle: Float) -> Float {
            var wrapped = angle.truncatingRemainder(dividingBy: 2 * .pi)
            if wrapped > .pi { wrapped -= 2 * .pi }
            if wrapped < -.pi { wrapped += 2 * .pi }
            return wrapped
        }

        /// Grille, ombre et trait vertical qui donnent la hauteur et la vitesse sol de l'avion.
        private func updateGroundReferences(at position: SIMD3<Float>) {
            groundGrid.simdPosition = SIMD3<Float>(
                (position.x / gridSpacing).rounded() * gridSpacing,
                0,
                (position.z / gridSpacing).rounded() * gridSpacing
            )
            groundShadow.simdPosition = SIMD3<Float>(position.x, 0.4, position.z)
            let height = max(0, position.y)
            dropLine.isHidden = height < 1
            dropLine.simdScale = SIMD3<Float>(1, max(height, 0.01), 1)
            dropLine.simdPosition = SIMD3<Float>(position.x, height / 2, position.z)
        }

        // MARK: - Traînée

        private func updateTrail(
            seconds: TimeInterval,
            samples: [FlightSample],
            mountingPitch: Double,
            isInverted: Bool
        ) {
            let firstTime = knotTimes[0]
            let pointCount = trailPointCount
            let step = trailDuration / Double(pointCount - 1)
            var centers: [SIMD3<Float>] = []
            var lefts: [SIMD3<Float>] = []
            var rights: [SIMD3<Float>] = []
            var speeds: [Double] = []
            var fades: [Float] = []
            for pointIndex in 0..<pointCount {
                let time = seconds - trailDuration + Double(pointIndex) * step
                guard time >= firstTime else { continue }
                let sample = samples[sampleIndex(at: time, in: samples)]
                let orientation = yawQuaternion(headingCorrection(at: time))
                    * sceneOrientation(of: sample, mountingPitch: mountingPitch, isInverted: isInverted)
                let right = orientation.act(SIMD3<Float>(1, 0, 0)) * wingHalfSpan
                let center = worldPosition(at: time)
                centers.append(center)
                lefts.append(center - right)
                rights.append(center + right)
                speeds.append(sample.speed)
                fades.append(Float(max(0, min(1, 1 - (seconds - time) / trailDuration))))
            }
            guard centers.count > 2 else {
                centerTrail.geometry = nil
                leftTrail.geometry = nil
                rightTrail.geometry = nil
                trailRungs.geometry = nil
                return
            }

            var segmentIndices: [Int32] = []
            for index in 0..<(centers.count - 1) {
                segmentIndices.append(Int32(index))
                segmentIndices.append(Int32(index + 1))
            }
            let centerColors = zip(speeds, fades).map { speed, fade -> SIMD4<Float> in
                var color = Self.speedColor(speed)
                color.w = fade
                return color
            }
            let leftColors = fades.map { SIMD4<Float>(1, 0.2, 0.2, $0) }
            let rightColors = fades.map { SIMD4<Float>(0.2, 0.9, 0.3, $0) }
            centerTrail.geometry = Self.geometry(
                vertices: centers, colors: centerColors, indices: segmentIndices, primitive: .line
            )
            leftTrail.geometry = Self.geometry(
                vertices: lefts, colors: leftColors, indices: segmentIndices, primitive: .line
            )
            rightTrail.geometry = Self.geometry(
                vertices: rights, colors: rightColors, indices: segmentIndices, primitive: .line
            )

            // Un barreau toutes les 0,25 s relie les saumons d'aile du même instant : il se vrille avec
            // le roulis. Calés sur des multiples de 0,25 s absolus, les barreaux défilent avec la traînée
            // au lieu de glisser dessus.
            let rungInterval = 0.25
            var rungVertices: [SIMD3<Float>] = []
            var rungColors: [SIMD4<Float>] = []
            let firstRung = Int(((seconds - trailDuration) / rungInterval).rounded(.up))
            let lastRung = Int((seconds / rungInterval).rounded(.down))
            if firstRung <= lastRung {
                for rung in firstRung...lastRung {
                    let time = Double(rung) * rungInterval
                    guard time >= firstTime else { continue }
                    let sample = samples[sampleIndex(at: time, in: samples)]
                    let orientation = yawQuaternion(headingCorrection(at: time))
                        * sceneOrientation(of: sample, mountingPitch: mountingPitch, isInverted: isInverted)
                    let right = orientation.act(SIMD3<Float>(1, 0, 0)) * wingHalfSpan
                    let center = worldPosition(at: time)
                    let fade = Float(max(0, min(1, 1 - (seconds - time) / trailDuration)))
                    let color = SIMD4<Float>(1, 1, 1, 0.8 * fade)
                    rungVertices += [center - right, center + right]
                    rungColors += [color, color]
                }
            }
            trailRungs.geometry = Self.geometry(
                vertices: rungVertices,
                colors: rungColors,
                indices: rungVertices.indices.map(Int32.init),
                primitive: .line
            )
        }

        // MARK: - Trajectoire et échantillons

        private func worldPosition(at time: TimeInterval) -> SIMD3<Float> {
            Self.interpolate(times: knotTimes, positions: knotPositions, at: time)
        }

        private static func interpolate(
            times: [Double],
            positions: [SIMD3<Float>],
            at time: TimeInterval
        ) -> SIMD3<Float> {
            let count = times.count
            guard count > 0 else { return .zero }
            if time <= times[0] { return positions[0] }
            if time >= times[count - 1] { return positions[count - 1] }
            var lower = 0
            var upper = count - 1
            while upper - lower > 1 {
                let middle = (lower + upper) / 2
                if times[middle] <= time { lower = middle } else { upper = middle }
            }
            let fraction = Float((time - times[lower]) / (times[upper] - times[lower]))
            return positions[lower] + (positions[upper] - positions[lower]) * fraction
        }

        private func sampleIndex(at time: TimeInterval, in samples: [FlightSample]) -> Int {
            var lower = 0
            var upper = samples.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if samples[middle].elapsed < time { lower = middle + 1 } else { upper = middle }
            }
            guard lower > 0 else { return 0 }
            guard lower < samples.count else { return samples.count - 1 }
            let before = samples[lower - 1]
            let after = samples[lower]
            return time - before.elapsed <= after.elapsed - time ? lower - 1 : lower
        }

        // MARK: - Attitude et cap absolu (même convention que Aircraft3DView)

        private let zUpToYUp = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))

        private func sceneOrientation(
            of sample: FlightSample,
            mountingPitch: Double,
            isInverted: Bool
        ) -> simd_quatf {
            let raw = simd_quatf(
                ix: Float(sample.quaternionX),
                iy: Float(sample.quaternionY),
                iz: Float(sample.quaternionZ),
                r: Float(sample.quaternionW)
            )
            let magnitude = simd_length(raw.vector)
            let sensor = magnitude.isFinite && magnitude > 0.000_001
                ? simd_quatf(vector: raw.vector / magnitude)
                : simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
            let pitchCorrection = simd_quatf(
                angle: Float(-mountingPitch * .pi / 180), axis: SIMD3<Float>(1, 0, 0)
            )
            let sensorToAircraftAxes = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            let inversion = simd_quatf(angle: isInverted ? .pi : 0, axis: SIMD3<Float>(0, 1, 0))
            let body = sensor * inversion * sensorToAircraftAxes * pitchCorrection
            return zUpToYUp * body * zUpToYUp.inverse
        }

        private func yawQuaternion(_ angle: Float) -> simd_quatf {
            simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0))
        }

        // Estimation du décalage entre le yaw des gyros et le nord (voir `HeadingEstimator`).
        private var headingEstimator = HeadingEstimator()
        // Série hors ligne du décalage de cap, une valeur tous les 0,1 s (voir `buildHeadingSeries`).
        private var headingSeries: [Float] = []
        private var headingSeriesStart: TimeInterval = 0

        private func resetHeadingEstimate() {
            headingEstimator.reset()
        }

        private func updateHeadingOffset(
            forward: SIMD3<Float>,
            up: SIMD3<Float>,
            heading: Double,
            speed: Double,
            loadFactor: Double
        ) {
            headingEstimator.update(
                forward: forward,
                up: up,
                heading: heading,
                speed: speed,
                loadFactor: loadFactor,
                now: ProcessInfo.processInfo.systemUptime
            )
        }

        // MARK: - Géométrie

        private static func speedColor(_ speed: Double) -> SIMD4<Float> {
            switch speed {
            case ..<113: SIMD4<Float>(0.0, 0.48, 1.0, 1)
            case ..<236: SIMD4<Float>(0.2, 0.78, 0.35, 1)
            case ..<300: SIMD4<Float>(1.0, 0.8, 0.0, 1)
            default: SIMD4<Float>(1.0, 0.23, 0.19, 1)
            }
        }

        private static func geometry(
            vertices: [SIMD3<Float>],
            colors: [SIMD4<Float>],
            indices: [Int32],
            primitive: SCNGeometryPrimitiveType
        ) -> SCNGeometry? {
            guard vertices.count > 1, !indices.isEmpty else { return nil }
            let vertexSource = SCNGeometrySource(vertices: vertices.map { SCNVector3($0) })
            let colorSource = SCNGeometrySource(
                data: colors.withUnsafeBytes { Data($0) },
                semantic: .color,
                vectorCount: colors.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SIMD4<Float>>.stride
            )
            let geometry = SCNGeometry(
                sources: [vertexSource, colorSource],
                elements: [SCNGeometryElement(indices: indices, primitiveType: primitive)]
            )
            geometry.firstMaterial?.lightingModel = .constant
            geometry.firstMaterial?.isDoubleSided = true
            geometry.firstMaterial?.writesToDepthBuffer = false
            return geometry
        }

        /// Tube triangulé le long de `points` (transport parallèle du repère), une couleur par point.
        private static func tubeGeometry(
            points: [SIMD3<Float>],
            colors: [SIMD4<Float>],
            radius: Float,
            sides: Int
        ) -> SCNGeometry? {
            guard points.count > 1 else { return nil }
            var vertices: [SIMD3<Float>] = []
            var vertexColors: [SIMD4<Float>] = []
            vertices.reserveCapacity(points.count * sides)
            vertexColors.reserveCapacity(points.count * sides)
            var normal = SIMD3<Float>(0, 1, 0)
            for index in points.indices {
                let tangent = points[min(index + 1, points.count - 1)] - points[max(index - 1, 0)]
                guard simd_length(tangent) > 0.000_001 else {
                    // Points confondus : on réutilise l'anneau précédent.
                    for side in 0..<sides {
                        vertices.append(vertices.isEmpty ? points[index] : vertices[vertices.count - sides])
                        vertexColors.append(colors[index])
                        _ = side
                    }
                    continue
                }
                let direction = simd_normalize(tangent)
                var candidate = normal - simd_dot(normal, direction) * direction
                if simd_length(candidate) < 0.001 {
                    candidate = abs(direction.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
                    candidate -= simd_dot(candidate, direction) * direction
                }
                normal = simd_normalize(candidate)
                let binormal = simd_cross(direction, normal)
                for side in 0..<sides {
                    let angle = Float(side) / Float(sides) * 2 * .pi
                    vertices.append(points[index] + (cos(angle) * normal + sin(angle) * binormal) * radius)
                    vertexColors.append(colors[index])
                }
            }

            var indices: [Int32] = []
            indices.reserveCapacity((points.count - 1) * sides * 6)
            for ring in 0..<(points.count - 1) {
                for side in 0..<sides {
                    let next = (side + 1) % sides
                    let a = Int32(ring * sides + side)
                    let b = Int32(ring * sides + next)
                    let c = Int32((ring + 1) * sides + side)
                    let d = Int32((ring + 1) * sides + next)
                    indices.append(contentsOf: [a, c, b, b, c, d])
                }
            }
            return geometry(vertices: vertices, colors: vertexColors, indices: indices, primitive: .triangles)
        }

        // MARK: - Scène

        private func loadModelIfNeeded(from url: URL?) {
            guard let url, url != currentModelURL else { return }
            guard let model = try? AircraftModelLoader.makeNode(from: url) else { return }
            modelRoot.childNodes.forEach { $0.removeFromParentNode() }
            modelRoot.addChildNode(model)
            currentModelURL = url
        }

        private func configureScene() {
            // Ciel en projection équirectangulaire : SceneKit la rend comme une skybox, l'horizon
            // reste donc fixe quel que soit l'angle de la caméra.
            scene.background.contents = Self.skyImage() ?? Self.skyColor
            // Brouillard léger, de la teinte de l'horizon : il fond seulement le lointain dans le ciel.
            scene.fogColor = Self.horizonColor
            scene.fogStartDistance = 5_000
            scene.fogEndDistance = 14_000
            scene.fogDensityExponent = 1

            modelRoot.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            aircraft.simdScale = SIMD3<Float>(repeating: modelScale)
            aircraft.addChildNode(modelRoot)
            modelRoot.addChildNode(makeFallbackModel())
            scene.rootNode.addChildNode(aircraft)

            scene.rootNode.addChildNode(makeGround())
            // SCNPlane est vertical : couché à plat, le haut de l'image pointe vers -Z (le nord).
            satelliteNode.simdEulerAngles = SIMD3<Float>(-.pi / 2, 0, 0)
            satelliteNode.isHidden = true
            scene.rootNode.addChildNode(satelliteNode)
            detailNode.simdEulerAngles = SIMD3<Float>(-.pi / 2, 0, 0)
            scene.rootNode.addChildNode(detailNode)
            configureGroundGrid()
            scene.rootNode.addChildNode(groundGrid)

            let shadow = SCNCylinder(radius: 6, height: 0.05)
            shadow.firstMaterial?.diffuse.contents = PlatformColor.black.withAlphaComponent(0.35)
            shadow.firstMaterial?.lightingModel = .constant
            groundShadow.geometry = shadow
            scene.rootNode.addChildNode(groundShadow)

            let drop = SCNCylinder(radius: 0.15, height: 1)
            drop.firstMaterial?.diffuse.contents = PlatformColor.systemTeal.withAlphaComponent(0.55)
            drop.firstMaterial?.lightingModel = .constant
            dropLine.geometry = drop
            scene.rootNode.addChildNode(dropLine)

            for node in [fullPathNode, centerTrail, leftTrail, rightTrail, trailRungs] {
                scene.rootNode.addChildNode(node)
            }

            let camera = SCNCamera()
            camera.fieldOfView = 60
            camera.zNear = 2
            camera.zFar = 12_000
            cameraNode.camera = camera
            cameraNode.simdPosition = cameraOffset
            scene.rootNode.addChildNode(cameraNode)

            scene.rootNode.addChildNode(makeLight(intensity: 1_650, color: (1, 0.96, 0.90), euler: SCNVector3(-0.75, 0.65, -0.25)))
            scene.rootNode.addChildNode(makeLight(intensity: 520, color: (0.72, 0.82, 1), euler: SCNVector3(0.45, -1.05, 0.35)))
            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 190
            let ambientNode = SCNNode()
            ambientNode.light = ambient
            scene.rootNode.addChildNode(ambientNode)
        }

        private func makeLight(intensity: CGFloat, color: (CGFloat, CGFloat, CGFloat), euler: SCNVector3) -> SCNNode {
            let light = SCNLight()
            light.type = .directional
            light.intensity = intensity
            light.color = PlatformColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            let node = SCNNode()
            node.light = light
            node.eulerAngles = euler
            return node
        }

        private func makeGround() -> SCNNode {
            // Simple plan plutôt que SCNFloor : ce dernier ajoute une passe de réflexion
            // (« FloorPass is not linked to the rendering graph ») au contrôle caméra souris.
            let floor = SCNPlane(width: 20_000, height: 20_000)
            floor.firstMaterial?.lightingModel = .constant
            floor.firstMaterial?.diffuse.contents = PlatformColor(red: 0.16, green: 0.24, blue: 0.17, alpha: 1)
            let node = SCNNode(geometry: floor)
            // Sous le plan satellite (y = 0) pour éviter le z-fighting.
            node.position.y = -1
            node.eulerAngles.x = -.pi / 2
            return node
        }

        /// Grille de repère au sol (pas de 100 m) recalée sur la position de l'avion par multiples du pas.
        private func configureGroundGrid() {
            let cells = 30
            let extent = Float(cells) * gridSpacing
            var vertices: [SIMD3<Float>] = []
            var colors: [SIMD4<Float>] = []
            for line in -cells...cells {
                let coordinate = Float(line) * gridSpacing
                let alpha: Float = line.isMultiple(of: 5) ? 0.35 : 0.14
                let color = SIMD4<Float>(0.75, 0.95, 0.85, alpha)
                vertices += [
                    SIMD3<Float>(-extent, 0.3, coordinate), SIMD3<Float>(extent, 0.3, coordinate),
                    SIMD3<Float>(coordinate, 0.3, -extent), SIMD3<Float>(coordinate, 0.3, extent),
                ]
                colors += [color, color, color, color]
            }
            groundGrid.geometry = Self.geometry(
                vertices: vertices,
                colors: colors,
                indices: vertices.indices.map(Int32.init),
                primitive: .line
            )
        }

        /// Avion simplifié, utilisé tant que le modèle STL n'est pas chargé.
        private func makeFallbackModel() -> SCNNode {
            let root = SCNNode()
            root.simdOrientation = simd_quatf(angle: .pi, axis: SIMD3<Float>(1, 0, 0))

            let fuselage = SCNCapsule(capRadius: 0.22, height: 2.8)
            fuselage.firstMaterial?.diffuse.contents = PlatformColor.systemRed
            let fuselageNode = SCNNode(geometry: fuselage)
            fuselageNode.eulerAngles.x = .pi / 2
            root.addChildNode(fuselageNode)

            let wing = SCNBox(width: 4.2, height: 0.08, length: 0.75, chamferRadius: 0.08)
            wing.firstMaterial?.diffuse.contents = PlatformColor.white
            let wingNode = SCNNode(geometry: wing)
            wingNode.position.z = 0.1
            root.addChildNode(wingNode)

            let fin = SCNBox(width: 0.06, height: 0.72, length: 0.42, chamferRadius: 0.03)
            fin.firstMaterial?.diffuse.contents = PlatformColor.systemRed
            let finNode = SCNNode(geometry: fin)
            finNode.position = SCNVector3(0, 0.34, 1.05)
            root.addChildNode(finNode)
            return root
        }
    }
}
