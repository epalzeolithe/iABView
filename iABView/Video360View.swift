import AVFoundation
import SceneKit
import SwiftUI
#if os(macOS)
import AppKit
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Lecture de `video360.mp4` (équirectangulaire) projetée sur l'intérieur d'une sphère SceneKit.
/// Glisser oriente la caméra ; molette, pincement ou trackpad règlent le champ de vision ;
/// double-clic (double-tap) revient à la vue initiale.
struct Video360View: PlatformViewRepresentable {
    let player: AVPlayer
    /// Lacet de départ en degrés (180 pour regarder vers l'avant de l'avion).
    var initialYaw: CGFloat = 0
    /// Décalage ajouté à l'orientation choisie à la souris (suivi dynamique).
    var dynamicOffset: Video360Offset = .zero
    /// Orientation imposée par un preset : appliquée chaque fois que `revision` change.
    var yawPreset: Video360YawPreset?
    /// Appelé quand le champ de vision change (molette, pincement, réinitialisation).
    var onFieldOfViewChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(initialYaw: initialYaw, presetRevision: yawPreset?.revision ?? 0)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> SCNView {
        let view = Video360SCNView()
        view.coordinator = context.coordinator
        configure(view, context: context)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.onFieldOfViewChange = onFieldOfViewChange
        context.coordinator.apply(yawPreset)
        context.coordinator.setPlayer(player)
        context.coordinator.setDynamicOffset(dynamicOffset)
    }
    #else
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        configure(view, context: context)
        context.coordinator.installGestures(on: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onFieldOfViewChange = onFieldOfViewChange
        context.coordinator.apply(yawPreset)
        context.coordinator.setPlayer(player)
        context.coordinator.setDynamicOffset(dynamicOffset)
    }
    #endif

    private func configure(_ view: SCNView, context: Context) {
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.backgroundColor = .black
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .none
        view.preferredFramesPerSecond = 30
        // La texture vidéo n'est rafraîchie que lorsque SceneKit redessine.
        view.rendersContinuously = true
        view.isPlaying = true
        context.coordinator.onFieldOfViewChange = onFieldOfViewChange
        context.coordinator.setPlayer(player)
        context.coordinator.setDynamicOffset(dynamicOffset)
    }

    @MainActor
    final class Coordinator: NSObject {
        static let defaultFieldOfView: CGFloat = 100
        private static let fieldOfViewRange: ClosedRange<CGFloat> = 25...120

        let scene = SCNScene()
        let cameraNode = SCNNode()
        private let yawNode = SCNNode()
        /// Porte le décalage dynamique, séparé de l'orientation manuelle pour pouvoir l'animer seul.
        private let dynamicNode = SCNNode()
        private let sphereMaterial = SCNMaterial()
        private weak var player: AVPlayer?

        /// Angles en degrés : lacet autour de la verticale, tangage borné à ±89°.
        private let initialYaw: CGFloat
        private var yaw: CGFloat
        private var dynamicOffset = Video360Offset.zero
        private var pitch: CGFloat = 0
        private(set) var fieldOfView = Coordinator.defaultFieldOfView
        var onFieldOfViewChange: (CGFloat) -> Void = { _ in }
        #if os(iOS)
        private var pinchStartFieldOfView = Coordinator.defaultFieldOfView
        #endif

        /// Dernier preset appliqué : un preset demandé avant la création de la vue n'est pas rejoué.
        private var presetRevision: Int

        init(initialYaw: CGFloat, presetRevision: Int) {
            self.initialYaw = initialYaw
            self.yaw = initialYaw
            self.presetRevision = presetRevision
            super.init()
            let sphere = SCNSphere(radius: 10)
            sphere.segmentCount = 96
            // Vue depuis l'intérieur : on dessine les faces arrière, et on retourne la texture
            // horizontalement pour qu'elle ne soit pas vue en miroir.
            sphereMaterial.cullMode = .front
            sphereMaterial.lightingModel = .constant
            sphereMaterial.diffuse.wrapS = .repeat
            sphereMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(-1, 1, 1)
            sphere.firstMaterial = sphereMaterial
            scene.rootNode.addChildNode(SCNNode(geometry: sphere))

            let camera = SCNCamera()
            camera.zNear = 0.1
            camera.zFar = 50
            camera.fieldOfView = fieldOfView
            cameraNode.camera = camera
            // Nœuds imbriqués pour que lacet, tangage et décalage dynamique ne se mélangent pas.
            dynamicNode.addChildNode(cameraNode)
            yawNode.addChildNode(dynamicNode)
            scene.rootNode.addChildNode(yawNode)
            applyOrientation()
        }

        func setPlayer(_ player: AVPlayer) {
            guard self.player !== player else { return }
            self.player = player
            sphereMaterial.diffuse.contents = player
        }

        /// Déplacement du pointeur en points ; le nombre de degrés par point suit le champ de vision
        /// pour que l'image reste « sous le doigt » quel que soit le zoom.
        func rotate(byX deltaX: CGFloat, y deltaY: CGFloat, viewHeight: CGFloat) {
            let degreesPerPoint = fieldOfView / max(viewHeight, 1)
            yaw += deltaX * degreesPerPoint
            pitch = min(89, max(-89, pitch + deltaY * degreesPerPoint))
            applyOrientation()
        }

        /// Les échantillons arrivent par à-coups : une courte animation lisse les variations.
        func setDynamicOffset(_ offset: Video360Offset) {
            guard offset != dynamicOffset else { return }
            dynamicOffset = offset
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
            dynamicNode.eulerAngles = SCNVector3(
                CGFloat(offset.pitch * .pi / 180),
                0,
                CGFloat(-offset.roll * .pi / 180)
            )
            SCNTransaction.commit()
        }

        func setFieldOfView(_ value: CGFloat) {
            fieldOfView = min(Self.fieldOfViewRange.upperBound, max(Self.fieldOfViewRange.lowerBound, value))
            cameraNode.camera?.fieldOfView = fieldOfView
            onFieldOfViewChange(fieldOfView)
        }

        func apply(_ preset: Video360YawPreset?) {
            guard let preset, preset.revision != presetRevision else { return }
            presetRevision = preset.revision
            if preset.recenters {
                // Retour à l'orientation par défaut de la caméra 360° (angle équivalent le plus proche).
                yaw = initialYaw + 360 * ((yaw - initialYaw) / 360).rounded()
                pitch = 0
                setFieldOfView(Self.defaultFieldOfView)
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.4
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                applyOrientation()
                SCNTransaction.commit()
                return
            }
            // Angle équivalent le plus proche : l'animation prend le chemin court même après plusieurs tours.
            yaw = preset.yaw + 360 * ((yaw - preset.yaw) / 360).rounded()
            pitch = 0
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.4
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            applyOrientation()
            SCNTransaction.commit()
        }

        func reset() {
            yaw = initialYaw
            pitch = 0
            setFieldOfView(Self.defaultFieldOfView)
            applyOrientation()
        }

        private func applyOrientation() {
            yawNode.eulerAngles = SCNVector3(0, yaw * .pi / 180, 0)
            cameraNode.eulerAngles = SCNVector3(pitch * .pi / 180, 0, 0)
        }

        #if os(iOS)
        func installGestures(on view: SCNView) {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            view.addGestureRecognizer(pan)
            view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
            doubleTap.numberOfTapsRequired = 2
            view.addGestureRecognizer(doubleTap)
        }

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            rotate(byX: translation.x, y: translation.y, viewHeight: view.bounds.height)
            gesture.setTranslation(.zero, in: view)
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .began {
                pinchStartFieldOfView = fieldOfView
            }
            setFieldOfView(pinchStartFieldOfView / max(gesture.scale, 0.01))
        }

        @objc private func handleDoubleTap() {
            reset()
        }
        #endif
    }
}

/// Lacet (degrés) imposé par un bouton de preset ; `revision` change à chaque appui.
/// `recenters` ignore `yaw` et revient à l'orientation par défaut de la vue.
struct Video360YawPreset: Equatable {
    var yaw: CGFloat
    var revision: Int
    var recenters = false
}

/// Directions proposées par la croix de boutons, en lacet absolu (0° = avant de l'avion, 90° = gauche).
enum Video360Direction: CaseIterable {
    case front, back, left, right, center

    var yaw: CGFloat {
        switch self {
        case .front, .center: 0
        case .left: 90
        case .back: 180
        case .right: 270
        }
    }
}

/// Croix Avant / Arrière / Gauche / Droite avec, au centre, le recentrage sur l'orientation par défaut.
struct Video360DirectionPad: View {
    /// Faux : seul le bouton « recentrer » est affiché (layout 2).
    var showsDirections = true
    let onSelect: (Video360Direction) -> Void

    var body: some View {
        if showsDirections {
            fullPad
        } else {
            centerButton
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.35), lineWidth: 1))
        }
    }

    private var centerButton: some View {
        Button {
            onSelect(.center)
        } label: {
            Image(systemName: "scope")
                .frame(width: 22, height: 22)
        }
        .help("Recentrer sur l'orientation par défaut de la caméra 360°")
    }

    private var fullPad: some View {
        Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                button("Avant", symbol: "arrow.up", .front, help: "Regarder vers l'avant de l'avion")
            }
            GridRow {
                button("Gauche", symbol: "arrow.left", .left, help: "Regarder vers la gauche de l'avion")
                centerButton
                button("Droite", symbol: "arrow.right", .right, help: "Regarder vers la droite de l'avion")
            }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                button("Arrière", symbol: "arrow.down", .back, help: "Regarder vers l'arrière de l'avion")
            }
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.35), lineWidth: 1))
    }

    private func button(_ title: LocalizedStringKey, symbol: String, _ direction: Video360Direction, help: LocalizedStringKey) -> some View {
        Button { onSelect(direction) } label: {
            Image(systemName: symbol)
                .frame(width: 16, height: 16)
        }
        .accessibilityLabel(title)
        .help(help)
    }
}

/// Décalage du regard en degrés : tangage positif vers le haut, inclinaison positive vers la droite.
struct Video360Offset: Equatable, Sendable {
    var pitch: Double
    var roll: Double

    static let zero = Video360Offset(pitch: 0, roll: 0)
}

#if os(macOS)
/// SCNView qui transforme souris, molette et trackpad en orientation et champ de vision.
private final class Video360SCNView: SCNView {
    weak var coordinator: Video360View.Coordinator?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            coordinator?.reset()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        // NSEvent.deltaY est positif vers le bas : tirer l'image vers le bas fait regarder vers le haut.
        coordinator?.rotate(byX: event.deltaX, y: event.deltaY, viewHeight: bounds.height)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let coordinator else { return }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 0.15 : 2
        coordinator.setFieldOfView(coordinator.fieldOfView - event.scrollingDeltaY * scale)
    }

    override func magnify(with event: NSEvent) {
        guard let coordinator else { return }
        coordinator.setFieldOfView(coordinator.fieldOfView / max(0.01, 1 + event.magnification))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
#endif
