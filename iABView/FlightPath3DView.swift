import Charts
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

struct FlightPath3DView: View {
    let model: FlightViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedLoadSamples: [FlightSample] = []
    @State private var lastLoadSamplesCacheTime: TimeInterval = -.infinity

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(white: 0.12) : .white
    }

    // Recomputed on every ~15 Hz playback tick (this view reads `model.currentIndex`
    // directly), so this needs to stay cheap regardless of sample density. At the
    // ~100 Hz IMU rate this project works with, the prior linear backward scan
    // over a 20s window walked up to ~2000 samples per call, and handed all 2000
    // to the load-history Chart as individual LineMarks — a continuous, sustained
    // cost on top of everything else competing for the main thread. Binary search
    // plus capping the chart to ~200 points (already more than a narrow sidebar
    // chart can usefully render) removes both the O(n) scan and the oversized
    // Chart workload.
    private func recentLoadSamples() -> [FlightSample] {
        guard model.samples.indices.contains(model.currentIndex) else { return [] }
        let startTime = max(0, model.currentTime - 20)
        let startIndex = firstSampleIndex(atOrAfter: startTime, upperBound: model.currentIndex)
        let window = model.samples[startIndex...model.currentIndex]

        let maximumPoints = 200
        guard window.count > maximumPoints else { return Array(window) }
        let strideValue = max(1, window.count / maximumPoints)
        return window.enumerated().compactMap { offset, sample in
            offset.isMultiple(of: strideValue) ? sample : nil
        }
    }

    // A slowly-scrolling 20s trend line doesn't need to redraw at the same rate
    // as the rest of the UI: Swift Charts laying out ~200 marks isn't free, and
    // doing it on every tick added up on top of everything else. Refreshing the
    // cache at most 5x/second (instead of relying on the ~15 Hz tick driving
    // this view) is visually indistinguishable for this chart.
    private func refreshLoadSamplesCacheIfNeeded() {
        guard model.currentTime - lastLoadSamplesCacheTime >= 0.2
            || model.currentTime < lastLoadSamplesCacheTime else { return }
        lastLoadSamplesCacheTime = model.currentTime
        cachedLoadSamples = recentLoadSamples()
    }

    private func firstSampleIndex(atOrAfter time: TimeInterval, upperBound: Int) -> Int {
        var lower = 0
        var upper = upperBound
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if model.samples[middle].elapsed < time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower
    }

    var body: some View {
        FlightPathScene(
            model: model,
            cameraZoomCommand: 0,
            colorScheme: colorScheme
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 8) {
                FlightPathGScale(loadFactor: model.currentSignedLoadFactor)
                    .frame(width: 170)

                FlightPathLoadHistory(
                    samples: cachedLoadSamples,
                    currentTime: lastLoadSamplesCacheTime,
                    mountingPitch: model.mountingPitch
                )
                .frame(maxWidth: .infinity)
                .frame(height: 86)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .allowsHitTesting(false)
        }
        .onAppear(perform: refreshLoadSamplesCacheIfNeeded)
        .onChange(of: model.currentIndex) { _, _ in refreshLoadSamplesCacheIfNeeded() }
        .overlay(alignment: .bottomLeading) {
            if model.currentSample?.gps2 != nil {
                FlightPathGPSLegend()
                .padding(12)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if let sample = model.currentSample, let other = sample.gps2 {
                    FlightPathDualGauges(
                        primary: model.activeGPSSource == .primary ? sample.gps : other,
                        secondary: model.activeGPSSource == .primary ? other : sample.gps,
                        maximumAltitude: max(model.maximumAltitude, model.secondaryMaximumAltitude),
                        maximumSpeed: max(model.maximumSpeed, model.secondaryMaximumSpeed)
                    )
                } else {
                    HStack(alignment: .bottom, spacing: 1) {
                        Spacer()
                        FlightPathAltitudeScale(
                            altitude: model.currentSample?.altitude ?? 0,
                            maximumAltitude: model.maximumAltitude
                        )
                        FlightPathSpeedScale(
                            speed: model.currentSample?.speed ?? 0,
                            maximumSpeed: model.maximumSpeed
                        )
                    }
                }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
        .background(backgroundColor)
    }
}

private struct FlightPathScene: PlatformViewRepresentable {
    let model: FlightViewModel
    let cameraZoomCommand: Int
    let colorScheme: ColorScheme

    private var platformBackgroundColor: PlatformColor {
        colorScheme == .dark ? PlatformColor(white: 0.12, alpha: 1) : .white
    }

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
        view.backgroundColor = platformBackgroundColor
        // Same tradeoff as Aircraft3DView: this renders on demand but still
        // frequently during playback, and 2x MSAA is plenty for this panel's
        // on-screen size while costing roughly half the GPU fragment work of 4x.
        view.antialiasingMode = .multisampling2X
        view.allowsCameraControl = true
        view.scene = context.coordinator.scene
        context.coordinator.configure(
            samples: model.samples,
            samplesRevision: model.samplesRevision,
            currentIndex: model.currentIndex,
            bundleURL: model.bundleURL,
            showsSecondaryGPS: model.showsBothGPSTrajectories,
            activeIsPrimary: model.activeGPSSource == .primary,
            view: view
        )
        return view
    }

    private func updateView(_ view: SCNView, context: Context) {
        view.backgroundColor = platformBackgroundColor
        context.coordinator.configure(
            samples: model.samples,
            samplesRevision: model.samplesRevision,
            currentIndex: model.currentIndex,
            bundleURL: model.bundleURL,
            showsSecondaryGPS: model.showsBothGPSTrajectories,
            activeIsPrimary: model.activeGPSSource == .primary,
            view: view
        )
        if let sample = model.currentSample {
            context.coordinator.updateMarker(
                sample: sample, showsSecondaryGPS: model.showsBothGPSTrajectories,
                activeIsPrimary: model.activeGPSSource == .primary, view: view
            )
        }
        context.coordinator.applyZoomCommand(cameraZoomCommand, view: view)
    }

    final class Coordinator: NSObject {
        let scene = SCNScene()
        private let marker = SCNNode(
            geometry: SCNSphere(radius: 0.045)
        )
        private let secondaryMarker = SCNNode(
            geometry: SCNSphere(radius: 0.045)
        )
        private let verticalLine = SCNNode()
        private var mainLineColor: PlatformColor?
        private var otherLineColor = PlatformColor.systemPink
        private let cameraNode = SCNNode()
        private var reference: FlightReference?
        private var configuredBundleURL: URL?
        private var configuredRevision = -1
        private var lastTrajectoryEndTime: TimeInterval?
        private var cameraTarget: SCNVector3?
        private var appliedZoomCommand = 0
        private var colorComponentCache: [PlatformColor: (Float, Float, Float, Float)] = [:]

        override init() {
            super.init()
            marker.geometry?.firstMaterial?.diffuse.contents = PlatformColor.systemRed
            scene.rootNode.addChildNode(marker)
            secondaryMarker.geometry?.firstMaterial?.diffuse.contents = PlatformColor.systemPink
            secondaryMarker.isHidden = true
            scene.rootNode.addChildNode(secondaryMarker)
            scene.rootNode.addChildNode(verticalLine)
            addCamera()
            addLights()
        }

        func configure(
            samples: [FlightSample],
            samplesRevision: Int,
            currentIndex: Int,
            bundleURL: URL?,
            showsSecondaryGPS: Bool,
            activeIsPrimary: Bool,
            view: SCNView
        ) {
            guard let first = samples.first, samples.indices.contains(currentIndex) else { return }
            let currentSample = samples[currentIndex]
            let bundleChanged = configuredBundleURL != bundleURL
            // Échantillons remplacés (ex. décalage GPS) : la trajectoire doit être reconstruite
            // même à l'arrêt, sans attendre la seconde de lecture suivante.
            let samplesChanged = configuredRevision != samplesRevision
            configuredRevision = samplesRevision

            if bundleChanged {
                configuredBundleURL = bundleURL
                reference = FlightReference(
                    latitude: first.latitude,
                    longitude: first.longitude,
                    cosineLatitude: cos(first.latitude * .pi / 180)
                )
                lastTrajectoryEndTime = nil
                cameraTarget = nil
            }

            // Avec 2 GPS : GPS principal en bleu uni, GPS2 en rose uni (au lieu des couleurs de vitesse).
            let principalColor = PlatformColor.systemBlue
            let secondaryColor = PlatformColor.systemPink
            mainLineColor = showsSecondaryGPS ? (activeIsPrimary ? principalColor : secondaryColor) : nil
            otherLineColor = activeIsPrimary ? secondaryColor : principalColor

            let shouldRefreshTrajectory = bundleChanged
                || samplesChanged
                || lastTrajectoryEndTime == nil
                || currentSample.elapsed < (lastTrajectoryEndTime ?? 0)
                || currentSample.elapsed - (lastTrajectoryEndTime ?? 0) >= 1
            guard shouldRefreshTrajectory else { return }

            let previousTrajectory = scene.rootNode.childNode(
                withName: "trajectory",
                recursively: false
            )
            let previousShadow = scene.rootNode.childNode(
                withName: "shadow",
                recursively: false
            )
            let previousGround = scene.rootNode.childNode(
                withName: "ground",
                recursively: false
            )
            let previousSecondary = scene.rootNode.childNode(
                withName: "secondaryTrajectory",
                recursively: false
            )

            let startTime = max(0, currentSample.elapsed - 90)
            let startIndex = firstSampleIndex(
                atOrAfter: startTime,
                samples: samples,
                upperBound: currentIndex
            )
            let windowSamples = Array(samples[startIndex...currentIndex])
            let visibleSamples = downsampled(windowSamples, maximumCount: 8_000)
            addTrajectory(samples: visibleSamples)
            addGround(samples: visibleSamples)
            if showsSecondaryGPS { addSecondaryTrajectory(samples: visibleSamples) }
            previousSecondary?.removeFromParentNode()
            previousTrajectory?.removeFromParentNode()
            previousShadow?.removeFromParentNode()
            previousGround?.removeFromParentNode()
            lastTrajectoryEndTime = currentSample.elapsed
        }

        private func firstSampleIndex(
            atOrAfter time: TimeInterval,
            samples: [FlightSample],
            upperBound: Int
        ) -> Int {
            var lower = 0
            var upper = upperBound
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if samples[middle].elapsed < time {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            return lower
        }

        private func downsampled(
            _ samples: [FlightSample],
            maximumCount: Int
        ) -> [FlightSample] {
            guard samples.count > maximumCount else { return samples }
            let strideValue = max(1, samples.count / maximumCount)
            var result = Swift.stride(from: 0, to: samples.count, by: strideValue)
                .map { samples[$0] }
            if let last = samples.last, result.last?.id != last.id {
                result.append(last)
            }
            return result
        }

        func updateMarker(sample: FlightSample, showsSecondaryGPS: Bool, activeIsPrimary: Bool, view: SCNView) {
            guard let reference else { return }
            let position = position(for: sample, reference: reference)
            marker.position = position
            marker.geometry?.firstMaterial?.diffuse.contents = mainLineColor ?? PlatformColor.systemRed
            secondaryMarker.geometry?.firstMaterial?.diffuse.contents = otherLineColor
            if showsSecondaryGPS, let secondary = sample.gps2 {
                secondaryMarker.position = self.position(for: secondary, reference: reference)
                secondaryMarker.isHidden = false
            } else {
                secondaryMarker.isHidden = true
            }
            verticalLine.geometry = lineGeometry(
                from: SCNVector3(position.x, 0, position.z),
                to: position,
                color: .systemPurple
            )
            centerCamera(on: position, view: view)
        }

        private func centerCamera(on target: SCNVector3, view: SCNView) {
            let isInitialPosition = cameraTarget == nil
            let camera = isInitialPosition ? cameraNode : (view.pointOfView ?? cameraNode)
            if let previousTarget = cameraTarget {
                camera.position = SCNVector3(
                    camera.position.x + target.x - previousTarget.x,
                    camera.position.y + target.y - previousTarget.y,
                    camera.position.z + target.z - previousTarget.z
                )
            } else {
                camera.position = SCNVector3(
                    target.x + 3.2,
                    target.y + 2.4,
                    target.z + 4.8
                )
            }
            camera.look(at: target)
            if isInitialPosition {
                view.pointOfView = camera
                view.defaultCameraController.automaticTarget = false
            }
            view.defaultCameraController.target = target
            cameraTarget = target
        }

        func applyZoomCommand(_ command: Int, view: SCNView) {
            guard command != appliedZoomCommand, let target = cameraTarget else { return }
            let camera = view.pointOfView ?? cameraNode
            let factor: SCNFloat = command > appliedZoomCommand ? 0.8 : 1.25
            camera.position = SCNVector3(
                target.x + (camera.position.x - target.x) * factor,
                target.y + (camera.position.y - target.y) * factor,
                target.z + (camera.position.z - target.z) * factor
            )
            camera.look(at: target)
            view.defaultCameraController.target = target
            appliedZoomCommand = command
        }

        private func addTrajectory(samples: [FlightSample]) {
            guard let reference, samples.count > 1 else { return }
            let points = samples.map { position(for: $0, reference: reference) }
            let colors = samples.map { mainLineColor ?? speedColor($0.speed) }

            let visualExtent = points.reduce(SCNFloat(0)) { extent, vertex in
                max(extent, abs(vertex.x), abs(vertex.y), abs(vertex.z))
            }
            let trajectoryThickness = max(SCNFloat(0.008), visualExtent * 0.0015)
            let trajectory = tubeNode(
                points: points,
                colors: colors,
                radius: trajectoryThickness * 0.8,
                sides: 6
            )
            trajectory.name = "trajectory"

            let guideInterval: TimeInterval = 10
            for index in 1..<samples.count {
                let previousSlot = Int(samples[index - 1].elapsed / guideInterval)
                let currentSlot = Int(samples[index].elapsed / guideInterval)
                guard currentSlot != previousSlot else { continue }
                let position = position(for: samples[index], reference: reference)
                guard position.y > 0.02 else { continue }
                let guide = SCNNode(
                    geometry: lineGeometry(
                        from: SCNVector3(position.x, 0.004, position.z),
                        to: position,
                        color: PlatformColor.systemTeal.withAlphaComponent(0.28)
                    )
                )
                trajectory.addChildNode(guide)
            }
            scene.rootNode.addChildNode(trajectory)

            let shadow = tubeNode(
                points: points.map { SCNVector3($0.x, 0, $0.z) },
                colors: Array(repeating: PlatformColor.brown.withAlphaComponent(0.85), count: points.count),
                radius: trajectoryThickness * 0.6,
                sides: 4
            )
            shadow.name = "shadow"
            scene.rootNode.addChildNode(shadow)
        }

        /// Trajectoire du second jeu GPS, en rose uni pour la distinguer de la trajectoire colorée par la vitesse.
        private func addSecondaryTrajectory(samples: [FlightSample]) {
            guard let reference else { return }
            let points = samples.compactMap { $0.gps2 }.map { position(for: $0, reference: reference) }
            guard points.count > 1 else { return }
            let visualExtent = points.reduce(SCNFloat(0)) { extent, vertex in
                max(extent, abs(vertex.x), abs(vertex.y), abs(vertex.z))
            }
            let node = tubeNode(
                points: points,
                colors: Array(repeating: otherLineColor, count: points.count),
                radius: max(SCNFloat(0.008), visualExtent * 0.0015) * 0.8,
                sides: 6
            )
            node.name = "secondaryTrajectory"
            scene.rootNode.addChildNode(node)
        }

        private func addGround(samples: [FlightSample]) {
            guard let reference else { return }
            let positions = samples.map { position(for: $0, reference: reference) }
            let horizontalExtent = max(
                6,
                positions.reduce(0) { maximum, position in
                    max(maximum, abs(position.x), abs(position.z))
                } * 3
            )
            let grid = SCNNode()
            grid.name = "ground"

            let groundPlane = SCNPlane(
                width: CGFloat(horizontalExtent * 2),
                height: CGFloat(horizontalExtent * 2)
            )
            groundPlane.firstMaterial?.diffuse.contents = PlatformColor.systemTeal
                .withAlphaComponent(0.045)
            groundPlane.firstMaterial?.lightingModel = .constant
            groundPlane.firstMaterial?.isDoubleSided = true
            let groundPlaneNode = SCNNode(geometry: groundPlane)
            groundPlaneNode.eulerAngles.x = -.pi / 2
            grid.addChildNode(groundPlaneNode)

            for index in -40...40 {
                let coordinate = SCNFloat(index) * horizontalExtent / 40
                let isMajorLine = index.isMultiple(of: 5)
                let gridColor = PlatformColor.systemTeal.withAlphaComponent(
                    isMajorLine ? 0.34 : 0.11
                )
                grid.addChildNode(
                    SCNNode(
                        geometry: lineGeometry(
                            from: SCNVector3(-horizontalExtent, 0.002, coordinate),
                            to: SCNVector3(horizontalExtent, 0.002, coordinate),
                            color: gridColor
                        )
                    )
                )
                grid.addChildNode(
                    SCNNode(
                        geometry: lineGeometry(
                            from: SCNVector3(coordinate, 0.002, -horizontalExtent),
                            to: SCNVector3(coordinate, 0.002, horizontalExtent),
                            color: gridColor
                        )
                    )
                )
            }

            scene.rootNode.addChildNode(grid)
        }

        /// Tube triangulé (un seul maillage) le long de `points`, une couleur par point. Remplace les
        /// lignes SceneKit d'un pixel dupliquées : plus épais, lisible à toute distance et une seule
        /// géométrie à dessiner. Les points trop proches sont fusionnés pour limiter le nombre de sommets.
        private func tubeNode(
            points rawPoints: [SCNVector3],
            colors rawColors: [PlatformColor],
            radius: SCNFloat,
            sides: Int
        ) -> SCNNode {
            var points: [SIMD3<Float>] = []
            var colors: [PlatformColor] = []
            let minimumSpacing = Float(radius) * 0.8
            for (index, point) in rawPoints.enumerated() {
                let candidate = SIMD3<Float>(Float(point.x), Float(point.y), Float(point.z))
                let isLast = index == rawPoints.count - 1
                if let last = points.last, simd_distance(last, candidate) < minimumSpacing {
                    if isLast { points[points.count - 1] = candidate; colors[colors.count - 1] = rawColors[index] }
                    continue
                }
                points.append(candidate)
                colors.append(rawColors[index])
            }
            let node = SCNNode()
            guard points.count > 1 else { return node }

            var vertices: [SCNVector3] = []
            var colorValues: [Float] = []
            vertices.reserveCapacity(points.count * sides)
            colorValues.reserveCapacity(points.count * sides * 4)
            var normal = SIMD3<Float>(0, 1, 0)
            for index in points.indices {
                let tangent = simd_normalize(
                    points[min(index + 1, points.count - 1)] - points[max(index - 1, 0)]
                )
                // Transport parallèle : le repère du tube ne vrille pas d'un anneau à l'autre.
                var candidate = normal - simd_dot(normal, tangent) * tangent
                if simd_length(candidate) < 0.001 {
                    candidate = abs(tangent.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
                    candidate -= simd_dot(candidate, tangent) * tangent
                }
                normal = simd_normalize(candidate)
                let binormal = simd_cross(tangent, normal)
                let components = cachedComponents(for: colors[index])
                for side in 0..<sides {
                    let angle = Float(side) / Float(sides) * 2 * .pi
                    let offset = (cos(angle) * normal + sin(angle) * binormal) * Float(radius)
                    let vertex = points[index] + offset
                    vertices.append(SCNVector3(CGFloat(vertex.x), CGFloat(vertex.y), CGFloat(vertex.z)))
                    colorValues.append(contentsOf: [components.0, components.1, components.2, components.3])
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

            let colorSource = SCNGeometrySource(
                data: colorValues.withUnsafeBytes { Data($0) },
                semantic: .color,
                vectorCount: vertices.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            )
            let geometry = SCNGeometry(
                sources: [SCNGeometrySource(vertices: vertices), colorSource],
                elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
            )
            geometry.firstMaterial?.lightingModel = .constant
            geometry.firstMaterial?.isDoubleSided = true
            node.geometry = geometry
            return node
        }

        private func lineGeometry(
            from start: SCNVector3,
            to end: SCNVector3,
            color: PlatformColor
        ) -> SCNGeometry {
            let source = SCNGeometrySource(vertices: [start, end])
            let element = SCNGeometryElement(
                indices: [Int32(0), Int32(1)],
                primitiveType: .line
            )
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = color
            geometry.firstMaterial?.lightingModel = .constant
            return geometry
        }

        private func position(
            for sample: FlightSample,
            reference: FlightReference
        ) -> SCNVector3 {
            position(
                latitude: sample.latitude, longitude: sample.longitude,
                altitude: sample.altitude, reference: reference
            )
        }

        private func position(for gps: SecondaryGPS, reference: FlightReference) -> SCNVector3 {
            position(
                latitude: gps.latitude, longitude: gps.longitude,
                altitude: gps.altitude, reference: reference
            )
        }

        private func position(
            latitude: Double, longitude: Double, altitude: Double,
            reference: FlightReference
        ) -> SCNVector3 {
            let metersPerDegree = 111_320.0
            let east = (longitude - reference.longitude)
                * metersPerDegree * reference.cosineLatitude
            let north = (latitude - reference.latitude) * metersPerDegree
            let altitudeMeters = max(0, altitude * 0.3048)
            return SCNVector3(east / 500, altitudeMeters / 500, -north / 500)
        }

        private func cachedComponents(for color: PlatformColor) -> (Float, Float, Float, Float) {
            if let cached = colorComponentCache[color] { return cached }
            let components: (Float, Float, Float, Float)
            #if os(macOS)
            let converted = color.usingColorSpace(.deviceRGB) ?? color
            components = (
                Float(converted.redComponent),
                Float(converted.greenComponent),
                Float(converted.blueComponent),
                Float(converted.alphaComponent)
            )
            #else
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            components = (Float(red), Float(green), Float(blue), Float(alpha))
            #endif
            colorComponentCache[color] = components
            return components
        }

        private func speedColor(_ speed: Double) -> PlatformColor {
            switch speed {
            case ..<113:
                return .systemBlue
            case ..<236:
                return .systemGreen
            case ..<300:
                return .systemYellow
            default:
                return .systemRed
            }
        }

        private func addCamera() {
            let camera = SCNCamera()
            camera.zNear = 0.01
            camera.zFar = 500
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(3.2, 2.4, 4.8)
            cameraNode.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(cameraNode)
        }

        private func addLights() {
            let ambient = SCNLight()
            ambient.type = .ambient
            ambient.intensity = 700
            let node = SCNNode()
            node.light = ambient
            scene.rootNode.addChildNode(node)
        }
    }
}

private struct FlightReference {
    let latitude: Double
    let longitude: Double
    let cosineLatitude: Double
}

private struct FlightPathSpeedScale: View {
    let speed: Double
    let maximumSpeed: Double
    @Environment(\.colorScheme) private var colorScheme

    private var labelColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var fillColor: Color {
        switch speed {
        case ..<113:
            .blue
        case ..<236:
            .green
        case ..<300:
            .yellow
        default:
            .red
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(speed, format: .number.precision(.fractionLength(0))) km/h")
                    .font(.caption.monospacedDigit().bold())
                Text("\(maximumSpeed, format: .number.precision(.fractionLength(0))) max")
                    .font(.system(size: 8).monospacedDigit())
            }

            GeometryReader { proxy in
                let ratio = max(0, min(1, speed / max(1, maximumSpeed)))
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.gray.opacity(0.25))
                    Rectangle()
                        .fill(fillColor)
                        .frame(height: proxy.size.height * ratio)
                }
            }
            .frame(width: 9, height: 82)
        }
        .foregroundStyle(labelColor)
        .padding(6)
    }
}

private struct FlightPathGScale: View {
    let loadFactor: Double
    @Environment(\.colorScheme) private var colorScheme

    private var labelColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text("−2")
                Spacer()
                Text("Charge \(loadFactor, format: .number.precision(.fractionLength(1))) g")
                    .fontWeight(.bold)
                Spacer()
                Text("+4")
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    LinearGradient(
                        colors: [.blue, .cyan, .green, .yellow, .red, .purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 12)
                    Rectangle()
                        .fill(labelColor)
                        .frame(width: 3, height: 22)
                        .offset(
                            x: min(
                                proxy.size.width - 2,
                                max(0, (loadFactor + 2) / 6 * proxy.size.width)
                            )
                        )
                }
            }
            .frame(height: 22)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(labelColor)
        .padding(8)
    }
}

private struct FlightPathLoadHistory: View {
    let samples: [FlightSample]
    let currentTime: TimeInterval
    let mountingPitch: Double
    @Environment(\.colorScheme) private var colorScheme

    private var labelColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var timeDomain: ClosedRange<TimeInterval> {
        let upperBound = max(20, currentTime)
        return (upperBound - 20)...upperBound
    }

    var body: some View {
        HStack(spacing: 4) {
            VStack {
                Text("+4")
                Spacer(minLength: 0)
                Text("−2")
            }
            .font(.caption2.monospacedDigit())

            Chart {
                ForEach(samples) { sample in
                    LineMark(
                        x: .value("Temps", sample.elapsed),
                        y: .value(
                            "Charge",
                            sample.signedLoadFactor(mountingPitch: mountingPitch)
                        )
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }

                RuleMark(y: .value("Charge normale", 1))
                    .foregroundStyle(.gray.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .chartXScale(domain: timeDomain)
            .chartYScale(domain: -2.0...4.0)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
        }
        .foregroundStyle(labelColor)
        .padding(6)
        .accessibilityLabel("Facteur de charge")
    }
}

private struct FlightPathAltitudeScale: View {
    let altitude: Double
    let maximumAltitude: Double
    @Environment(\.colorScheme) private var colorScheme

    private var labelColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(altitude, format: .number.precision(.fractionLength(0))) ft")
                    .font(.caption.monospacedDigit().bold())
                Text("\(maximumAltitude, format: .number.precision(.fractionLength(0))) max")
                    .font(.system(size: 8).monospacedDigit())
            }

            GeometryReader { proxy in
                let ratio = max(0, min(1, altitude / max(1, maximumAltitude)))
                ZStack(alignment: .bottom) {
                    Rectangle().fill(.gray.opacity(0.25))
                    Rectangle()
                        .fill(altitude >= 3_000 && altitude <= 5_000 ? .green : .orange)
                        .frame(height: proxy.size.height * ratio)
                }
            }
            .frame(width: 9, height: 82)
        }
        .foregroundStyle(labelColor)
        .padding(6)
    }
}

/// Légende des couleurs de la vue trajectoire quand les deux jeux GPS sont affichés.
private struct FlightPathGPSLegend: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Capsule().fill(.blue).frame(width: 26, height: 5)
                Text("GPS principal GNS3000")
            }
            HStack(spacing: 6) {
                Capsule().fill(.pink).frame(width: 26, height: 5)
                Text("GPS2 GPX")
            }
        }
        .font(.caption2)
        .foregroundStyle(colorScheme == .dark ? .white : .black)
        .padding(6)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Jauges altitude, vitesse et vitesse verticale des deux jeux GPS, accolées deux à deux (même échelle)
/// pour comparer les écarts. La barre de gauche est le GPS principal (bleu), celle de droite le GPS2 (rose).
private struct FlightPathDualGauges: View {
    let primary: SecondaryGPS
    let secondary: SecondaryGPS
    let maximumAltitude: Double
    let maximumSpeed: Double
    private let verticalSpeedRange = 2_000.0

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            gauge(
                "ft", primary.altitude, secondary.altitude,
                lower: 0, upper: max(1, maximumAltitude),
                primaryColor: .blue
            )
            gauge(
                "km/h", primary.speed, secondary.speed,
                lower: 0, upper: max(1, maximumSpeed), primaryColor: .blue
            )
            gauge(
                "ft/min", primary.verticalSpeed, secondary.verticalSpeed,
                lower: -verticalSpeedRange, upper: verticalSpeedRange, primaryColor: .blue
            )
        }
    }

    private func gauge(
        _ unit: String, _ first: Double, _ second: Double,
        lower: Double, upper: Double, primaryColor: Color
    ) -> some View {
        HStack(alignment: .bottom, spacing: 4) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(first, format: .number.precision(.fractionLength(0))) \(unit)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.blue)
                Text("\(second, format: .number.precision(.fractionLength(0))) \(unit)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.pink)
            }
            HStack(alignment: .bottom, spacing: 0) {
                bar(first, lower: lower, upper: upper, color: primaryColor)
                bar(second, lower: lower, upper: upper, color: .pink)
            }
        }
        .padding(6)
    }

    /// Barre de 9 pt : remplie depuis le bas, ou depuis le zéro quand l'échelle est signée.
    private func bar(_ value: Double, lower: Double, upper: Double, color: Color) -> some View {
        GeometryReader { proxy in
            let height = proxy.size.height
            let zero = height * (upper / (upper - lower))
            let position = height * (upper - max(lower, min(upper, value))) / (upper - lower)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.gray.opacity(0.25))
                Rectangle()
                    .fill(color)
                    .frame(height: abs(zero - position))
                    .offset(y: min(zero, position))
                if lower < 0 {
                    Rectangle().fill(.gray).frame(height: 1).offset(y: zero)
                }
            }
        }
        .frame(width: 9, height: 82)
    }
}
