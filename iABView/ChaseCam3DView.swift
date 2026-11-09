import AVFoundation
import SceneKit
import simd
import SwiftUI
#if os(macOS)
import AppKit
private typealias PlatformColor = NSColor
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
private typealias PlatformColor = UIColor
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Cadrages disponibles pour la caméra de poursuite 3D.
enum ChaseCam3DPreset: String, CaseIterable, Identifiable {
    case close = "Proche"
    case standard = "Standard"
    case wide = "Large"
    case side = "Côté"
    case top = "Dessus"

    var id: String { rawValue }

    /// Distance caméra-avion, en mètres.
    var distance: Float {
        switch self {
        case .close: 22
        case .standard: 40
        case .wide: 90
        case .side: 45
        case .top: 70
        }
    }

    /// Élévation de la caméra au-dessus de l'avion, en radians.
    var elevation: Float {
        let degrees: Float = switch self {
        case .close: 12
        case .standard: 18
        case .wide: 25
        case .side: 8
        case .top: 70
        }
        return degrees * .pi / 180
    }

    /// Décalage d'azimut par rapport à l'arrière de la trajectoire, en radians.
    var azimuth: Float {
        self == .side ? .pi / 2 : 0
    }
}

/// Deuxième chase cam : l'avion STL (attitude, cap absolu, traînée) évolue à sa position GPS 3D
/// réelle, au milieu de la trajectoire complète, filmé par une caméra de poursuite dynamique.
struct ChaseCam3DView: View {
    let model: FlightViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var preset: ChaseCam3DPreset = .standard
    @State private var showsFullPath = true

    var body: some View {
        ChaseCam3DScene(
            samples: model.samples,
            samplesRevision: model.samplesRevision,
            player: model.frontPlayer,
            modelURL: model.aircraftModelURL,
            mountingPitch: model.mountingPitch,
            isInverted: model.isCameraInverted,
            preset: preset,
            showsFullPath: showsFullPath
        )
        .overlay(alignment: .topLeading) {
            ChaseCam3DHUD(model: model)
                .padding()
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            controls.padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Button("Fermer", systemImage: "xmark.circle.fill") { dismiss() }
                .labelStyle(.iconOnly)
                .font(.title2)
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            Picker("Cadrage", selection: $preset) {
                ForEach(ChaseCam3DPreset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Toggle("Trajectoire complète", isOn: $showsFullPath)
                .toggleStyle(.switch)
                .fixedSize()
        }
        .padding(10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
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
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.pointOfView = context.coordinator.cameraNode
        view.backgroundColor = Coordinator.skyColor
        view.antialiasingMode = .multisampling2X
        // La caméra est pilotée par le coordinator (poursuite dynamique).
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.delegate = context.coordinator
        // La caméra se lisse image par image : 60 fps pour un mouvement fluide.
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.rendersContinuously = false
        updateView(view, context: context)
        return view
    }

    private func updateView(_ view: SCNView, context: Context) {
        context.coordinator.configure(
            samples: samples,
            samplesRevision: samplesRevision,
            player: player,
            modelURL: modelURL,
            mountingPitch: mountingPitch,
            isInverted: isInverted,
            preset: preset,
            showsFullPath: showsFullPath
        )
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        static let skyColor = PlatformColor(red: 0.35, green: 0.48, blue: 0.60, alpha: 1)

        let scene = SCNScene()
        let cameraNode = SCNNode()
        private let aircraft = SCNNode()
        private let modelRoot = SCNNode()
        private let fullPathNode = SCNNode()
        private let groundGrid = SCNNode()
        private let groundShadow = SCNNode()
        private let dropLine = SCNNode()
        private let centerTrail = SCNNode()
        private let leftTrail = SCNNode()
        private let rightTrail = SCNNode()
        private let trailRibbon = SCNNode()

        /// 1 unité de scène = 1 m. Le modèle STL (≈ 4,2 u d'envergure) est agrandi à l'échelle réelle.
        private let modelScale: Float = 2
        private let wingHalfSpan: Float = 2.1 * 2
        private let trailDuration: TimeInterval = 15
        private let trailPointCount = 150
        private let gridSpacing: Float = 100

        private let lock = NSLock()
        private var samples: [FlightSample] = []
        private var revision = -1
        private weak var player: AVPlayer?
        private var mountingPitch = 15.0
        private var isInverted = false
        private var preset = ChaseCam3DPreset.standard
        private var currentModelURL: URL?

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
            showsFullPath: Bool
        ) {
            lock.lock()
            defer { lock.unlock() }
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
            guard needsRebuild else { return }
            revision = samplesRevision
            self.samples = samples
            rebuildWorld()
        }

        private func rebuildWorld() {
            knotTimes = []
            knotPositions = []
            centerTrail.geometry = nil
            leftTrail.geometry = nil
            rightTrail.geometry = nil
            trailRibbon.geometry = nil
            fullPathNode.geometry = nil
            lastTrailSeconds = -.infinity
            resetHeadingEstimate()
            needsCameraSnap = true
            hasChaseDirection = false
            guard let first = samples.first else { return }

            let metersPerDegree = 111_320.0
            let cosineLatitude = cos(first.latitude * .pi / 180)
            let groundAltitude = (samples.map(\.altitude).min() ?? 0) * 0.3048

            var speeds: [Double] = []
            var last: FlightSample?
            for sample in samples {
                if let last, last.latitude == sample.latitude,
                   last.longitude == sample.longitude, last.altitude == sample.altitude {
                    continue
                }
                let east = (sample.longitude - first.longitude) * metersPerDegree * cosineLatitude
                let north = (sample.latitude - first.latitude) * metersPerDegree
                knotTimes.append(sample.elapsed)
                knotPositions.append(
                    SIMD3<Float>(Float(east), Float(sample.altitude * 0.3048 - groundAltitude), Float(-north))
                )
                speeds.append(sample.speed)
                last = sample
            }
            guard knotPositions.count > 1 else { return }

            // Trajectoire complète, sous-échantillonnée, en tube coloré par la vitesse.
            let strideValue = max(1, knotPositions.count / 3_000)
            var points: [SIMD3<Float>] = []
            var colors: [SIMD4<Float>] = []
            for index in Swift.stride(from: 0, to: knotPositions.count, by: strideValue) {
                points.append(knotPositions[index])
                var color = Self.speedColor(speeds[index])
                color.w = 0.6
                colors.append(color)
            }
            fullPathNode.geometry = Self.tubeGeometry(points: points, colors: colors, radius: 1.2, sides: 5)
        }

        // MARK: - Boucle de rendu

        func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            lock.lock()
            let samples = samples
            let player = player
            let mountingPitch = mountingPitch
            let isInverted = isInverted
            let preset = preset
            let snapRequested = needsCameraSnap
            needsCameraSnap = false
            lock.unlock()

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

            let index = sampleIndex(at: seconds, in: samples)
            let sample = samples[index]
            let position = worldPosition(at: seconds)
            let velocity = worldPosition(at: seconds + 0.5) - worldPosition(at: seconds - 0.5)

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
            orientation = yawQuaternion(headingCorrection) * orientation

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            aircraft.simdPosition = position
            aircraft.simdOrientation = orientation
            updateGroundReferences(at: position)
            updateCamera(
                position: position,
                velocity: velocity,
                noseForward: orientation.act(SIMD3<Float>(0, 0, -1)),
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
            noseForward: SIMD3<Float>,
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

            let backHeading = chaseHeading + .pi + preset.azimuth
            let distance = preset.distance
            let targetOffset = SIMD3<Float>(
                sin(backHeading) * distance * cos(preset.elevation),
                distance * sin(preset.elevation) - chaseClimb * distance * 0.35,
                -cos(backHeading) * distance * cos(preset.elevation)
            )
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
            groundShadow.simdPosition = SIMD3<Float>(position.x, 0.1, position.z)
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
            let step = trailDuration / Double(trailPointCount - 1)
            var centers: [SIMD3<Float>] = []
            var lefts: [SIMD3<Float>] = []
            var rights: [SIMD3<Float>] = []
            var speeds: [Double] = []
            var fades: [Float] = []
            let yaw = yawQuaternion(headingCorrection)
            for pointIndex in 0..<trailPointCount {
                let time = seconds - trailDuration + Double(pointIndex) * step
                guard time >= firstTime else { continue }
                let sample = samples[sampleIndex(at: time, in: samples)]
                let orientation = yaw * sceneOrientation(of: sample, mountingPitch: mountingPitch, isInverted: isInverted)
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
                trailRibbon.geometry = nil
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

            // Ruban entre les saumons d'aile : il se vrille avec le roulis et rend la figure lisible.
            var ribbonVertices: [SIMD3<Float>] = []
            var ribbonColors: [SIMD4<Float>] = []
            var ribbonIndices: [Int32] = []
            for index in centers.indices {
                ribbonVertices.append(lefts[index])
                ribbonVertices.append(rights[index])
                let color = SIMD4<Float>(1, 1, 1, 0.22 * fades[index])
                ribbonColors.append(color)
                ribbonColors.append(color)
            }
            for index in 0..<(centers.count - 1) {
                let base = Int32(index * 2)
                ribbonIndices.append(contentsOf: [base, base + 1, base + 2, base + 1, base + 3, base + 2])
            }
            trailRibbon.geometry = Self.geometry(
                vertices: ribbonVertices, colors: ribbonColors, indices: ribbonIndices, primitive: .triangles
            )
        }

        // MARK: - Trajectoire et échantillons

        private func worldPosition(at time: TimeInterval) -> SIMD3<Float> {
            let count = knotTimes.count
            guard count > 0 else { return .zero }
            if time <= knotTimes[0] { return knotPositions[0] }
            if time >= knotTimes[count - 1] { return knotPositions[count - 1] }
            var lower = 0
            var upper = count - 1
            while upper - lower > 1 {
                let middle = (lower + upper) / 2
                if knotTimes[middle] <= time { lower = middle } else { upper = middle }
            }
            let fraction = Float((time - knotTimes[lower]) / (knotTimes[upper] - knotTimes[lower]))
            return knotPositions[lower] + (knotPositions[upper] - knotPositions[lower]) * fraction
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

        // Le décalage entre le yaw des gyros et le nord est quasi constant : un filtre
        // complémentaire l'estime quand l'azimut du nez est une mesure fiable (nez proche de
        // l'horizontale, vol stabilisé) et le gèle sinon (boucles, figures).
        private let headingTimeConstant: Float = 3
        private var headingCorrection: Float = 0
        private var headingIsSeeded = false
        private var hasHeadingEstimate = false
        private var lastHeadingUptime: TimeInterval?
        private var previousNoseForward: SIMD3<Float>?

        private func resetHeadingEstimate() {
            lastHeadingUptime = nil
            headingIsSeeded = false
            previousNoseForward = nil
        }

        private func smoothstep(_ x: Float, _ low: Float, _ high: Float) -> Float {
            let t = max(0, min(1, (x - low) / (high - low)))
            return t * t * (3 - 2 * t)
        }

        private func updateHeadingOffset(
            forward: SIMD3<Float>,
            up: SIMD3<Float>,
            heading: Double,
            speed: Double,
            loadFactor: Double
        ) {
            let now = ProcessInfo.processInfo.systemUptime
            let dt = lastHeadingUptime.map { Float(now - $0) }
            defer {
                lastHeadingUptime = now
                previousNoseForward = forward
            }

            let horizontal = simd_length(SIMD2<Float>(forward.x, forward.z))
            var weight = smoothstep(horizontal, 0.64, 0.82)
            weight *= smoothstep(Float(speed), 30, 60)
            weight *= 1 - smoothstep(Float(abs(loadFactor - 1)), 0.25, 0.7)
            weight *= smoothstep(abs(up.y), 0.5, 0.8)
            if let dt, dt > 0, dt < 1, let previous = previousNoseForward {
                let angle = acos(max(-1, min(1, simd_dot(previous, forward))))
                weight *= 1 - smoothstep(angle / dt, 0.5, 1.5)
            }
            guard simd_length(SIMD2<Float>(forward.x, forward.z)) > 0.05 else { return }
            let target = atan2(forward.x, -forward.z) - Float(heading * .pi / 180)

            guard headingIsSeeded else {
                if weight > 0.5 {
                    headingCorrection = target
                    headingIsSeeded = true
                    hasHeadingEstimate = true
                } else if !hasHeadingEstimate {
                    headingCorrection = target
                }
                return
            }
            guard weight > 0 else { return }
            guard let dt, dt < 1 else {
                if weight > 0.5 { headingCorrection = target }
                return
            }
            headingCorrection += wrappedAngle(target - headingCorrection)
                * weight * (1 - exp(-dt / headingTimeConstant))
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
            guard let geometry = try? STLGeometryLoader.load(from: url) else { return }
            let model = SCNNode(geometry: geometry)
            let zCorrection = simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 0, 1))
            let tiltCorrection = simd_quatf(angle: Float(5 * Double.pi / 180), axis: SIMD3<Float>(1, 0, 0))
            model.simdOrientation = zCorrection * tiltCorrection
            modelRoot.childNodes.forEach { $0.removeFromParentNode() }
            modelRoot.addChildNode(model)
            currentModelURL = url
        }

        private func configureScene() {
            scene.background.contents = Self.skyColor
            scene.fogColor = Self.skyColor
            scene.fogStartDistance = 1_500
            scene.fogEndDistance = 7_000
            scene.fogDensityExponent = 1

            modelRoot.simdOrientation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0))
            aircraft.simdScale = SIMD3<Float>(repeating: modelScale)
            aircraft.addChildNode(modelRoot)
            modelRoot.addChildNode(makeFallbackModel())
            scene.rootNode.addChildNode(aircraft)

            scene.rootNode.addChildNode(makeGround())
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

            for node in [fullPathNode, centerTrail, leftTrail, rightTrail, trailRibbon] {
                scene.rootNode.addChildNode(node)
            }

            let camera = SCNCamera()
            camera.fieldOfView = 60
            camera.zNear = 1
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
            let floor = SCNFloor()
            floor.reflectivity = 0
            floor.firstMaterial?.lightingModel = .constant
            floor.firstMaterial?.diffuse.contents = PlatformColor(red: 0.16, green: 0.24, blue: 0.17, alpha: 1)
            return SCNNode(geometry: floor)
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
                    SIMD3<Float>(-extent, 0.05, coordinate), SIMD3<Float>(extent, 0.05, coordinate),
                    SIMD3<Float>(coordinate, 0.05, -extent), SIMD3<Float>(coordinate, 0.05, extent),
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
