import Charts
import SceneKit
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

    private var recentLoadSamples: [FlightSample] {
        guard model.samples.indices.contains(model.currentIndex) else { return [] }
        let startTime = max(0, model.currentTime - 20)
        var startIndex = model.currentIndex
        while startIndex > 0 && model.samples[startIndex - 1].elapsed >= startTime {
            startIndex -= 1
        }
        return Array(model.samples[startIndex...model.currentIndex])
    }

    var body: some View {
        FlightPathScene(
            model: model,
            cameraZoomCommand: 0
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 8) {
                FlightPathGScale(loadFactor: model.currentSignedLoadFactor)
                    .frame(width: 170)

                FlightPathLoadHistory(
                    samples: recentLoadSamples,
                    currentTime: model.currentTime,
                    mountingPitch: model.mountingPitch
                )
                .frame(maxWidth: .infinity)
                .frame(height: 86)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
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
            .padding(12)
            .allowsHitTesting(false)
        }
        .background(.white)
    }
}

private struct FlightPathScene: PlatformViewRepresentable {
    let model: FlightViewModel
    let cameraZoomCommand: Int

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
        view.backgroundColor = .white
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.scene = context.coordinator.scene
        context.coordinator.configure(
            samples: model.samples,
            currentIndex: model.currentIndex,
            bundleURL: model.bundleURL,
            view: view
        )
        return view
    }

    private func updateView(_ view: SCNView, context: Context) {
        context.coordinator.configure(
            samples: model.samples,
            currentIndex: model.currentIndex,
            bundleURL: model.bundleURL,
            view: view
        )
        if let sample = model.currentSample {
            context.coordinator.updateMarker(sample: sample, view: view)
        }
        context.coordinator.applyZoomCommand(cameraZoomCommand, view: view)
    }

    final class Coordinator: NSObject {
        let scene = SCNScene()
        private let marker = SCNNode(
            geometry: SCNSphere(radius: 0.045)
        )
        private let verticalLine = SCNNode()
        private let cameraNode = SCNNode()
        private var reference: FlightReference?
        private var configuredBundleURL: URL?
        private var lastTrajectoryEndTime: TimeInterval?
        private var cameraTarget: SCNVector3?
        private var appliedZoomCommand = 0

        override init() {
            super.init()
            marker.geometry?.firstMaterial?.diffuse.contents = PlatformColor.systemRed
            scene.rootNode.addChildNode(marker)
            scene.rootNode.addChildNode(verticalLine)
            addCamera()
            addLights()
        }

        func configure(
            samples: [FlightSample],
            currentIndex: Int,
            bundleURL: URL?,
            view: SCNView
        ) {
            guard let first = samples.first, samples.indices.contains(currentIndex) else { return }
            let currentSample = samples[currentIndex]
            let bundleChanged = configuredBundleURL != bundleURL

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

            let shouldRefreshTrajectory = bundleChanged
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

        func updateMarker(sample: FlightSample, view: SCNView) {
            guard let reference else { return }
            let position = position(for: sample, reference: reference)
            marker.position = position
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
            var vertices: [SCNVector3] = []
            var colors: [PlatformColor] = []
            var shadowVertices: [SCNVector3] = []

            for index in 1..<samples.count {
                let previous = position(for: samples[index - 1], reference: reference)
                let current = position(for: samples[index], reference: reference)
                vertices.append(contentsOf: [previous, current])
                shadowVertices.append(
                    contentsOf: [
                        SCNVector3(previous.x, 0, previous.z),
                        SCNVector3(current.x, 0, current.z)
                    ]
                )
                let color = speedColor(samples[index].speed)
                colors.append(contentsOf: [color, color])
            }

            let visualExtent = vertices.reduce(SCNFloat(0)) { extent, vertex in
                max(extent, abs(vertex.x), abs(vertex.y), abs(vertex.z))
            }
            let trajectoryThickness = max(SCNFloat(0.008), visualExtent * 0.0015)
            let trajectory = lineNode(
                vertices: vertices,
                colors: colors,
                thickness: trajectoryThickness
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

            let shadowColors = Array(
                repeating: PlatformColor.brown.withAlphaComponent(0.85),
                count: shadowVertices.count
            )
            let shadow = lineNode(
                vertices: shadowVertices,
                colors: shadowColors,
                thickness: trajectoryThickness * 0.75
            )
            shadow.name = "shadow"
            scene.rootNode.addChildNode(shadow)
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

        private func lineNode(
            vertices: [SCNVector3],
            colors: [PlatformColor],
            thickness: SCNFloat
        ) -> SCNNode {
            let vertexSource = SCNGeometrySource(vertices: vertices)
            let colorComponents: [Float] = colors.flatMap { color in
                #if os(macOS)
                let converted = color.usingColorSpace(.deviceRGB) ?? color
                return [
                    Float(converted.redComponent),
                    Float(converted.greenComponent),
                    Float(converted.blueComponent),
                    Float(converted.alphaComponent)
                ]
                #else
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                return [Float(red), Float(green), Float(blue), Float(alpha)]
                #endif
            }
            let colorData = colorComponents.withUnsafeBytes { Data($0) }
            let colorSource = SCNGeometrySource(
                data: colorData,
                semantic: .color,
                vectorCount: colors.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 4
            )
            let indices = vertices.indices.map(Int32.init)
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geometry = SCNGeometry(
                sources: [vertexSource, colorSource],
                elements: [element]
            )
            geometry.firstMaterial?.lightingModel = .constant

            // SceneKit draws line primitives one pixel wide. Reuse the same geometry
            // around the original path to keep it legible at every camera distance.
            let container = SCNNode()
            let offsets = [
                SCNVector3Zero,
                SCNVector3(thickness, 0, 0),
                SCNVector3(-thickness, 0, 0),
                SCNVector3(0, thickness, 0),
                SCNVector3(0, 0, thickness),
                SCNVector3(0, 0, -thickness)
            ]
            for offset in offsets {
                let line = SCNNode(geometry: geometry)
                line.position = offset
                container.addChildNode(line)
            }
            return container
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
            let metersPerDegree = 111_320.0
            let east = (sample.longitude - reference.longitude)
                * metersPerDegree * reference.cosineLatitude
            let north = (sample.latitude - reference.latitude) * metersPerDegree
            let altitudeMeters = max(0, sample.altitude * 0.3048)
            return SCNVector3(east / 500, altitudeMeters / 500, -north / 500)
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
        .foregroundStyle(.primary)
        .padding(6)
    }
}

private struct FlightPathGScale: View {
    let loadFactor: Double

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
                        .fill(.black)
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
        .foregroundStyle(.primary)
        .padding(8)
        .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 5))
    }
}

private struct FlightPathLoadHistory: View {
    let samples: [FlightSample]
    let currentTime: TimeInterval
    let mountingPitch: Double

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
        .foregroundStyle(.primary)
        .padding(6)
        .background(.white.opacity(0.84), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("Facteur de charge")
    }
}

private struct FlightPathAltitudeScale: View {
    let altitude: Double
    let maximumAltitude: Double

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
        .foregroundStyle(.primary)
        .padding(6)
    }
}
