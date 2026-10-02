import SceneKit
import SwiftUI

struct FlightPath3DView: View {
    let model: FlightViewModel

    var body: some View {
        ZStack {
            FlightPathScene(model: model)

            VStack {
                FlightPathSpeedScale(speed: model.currentSample?.speed ?? 0)
                Spacer()
                HStack(alignment: .bottom) {
                    FlightPathGScale(loadFactor: model.currentSignedLoadFactor)
                    Spacer()
                    FlightPathAltitudeScale(
                        altitude: model.currentSample?.altitude ?? 0,
                        maximumAltitude: model.maximumAltitude
                    )
                }
            }
            .padding(12)
            .allowsHitTesting(false)
        }
        .background(.black)
    }
}

private struct FlightPathScene: NSViewRepresentable {
    let model: FlightViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.scene = context.coordinator.scene
        context.coordinator.configure(samples: model.samples, bundleURL: model.bundleURL)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.configure(samples: model.samples, bundleURL: model.bundleURL)
        if let sample = model.currentSample {
            context.coordinator.updateMarker(sample: sample)
        }
    }

    final class Coordinator {
        let scene = SCNScene()
        private let marker = SCNNode(
            geometry: SCNSphere(radius: 0.045)
        )
        private let verticalLine = SCNNode()
        private var reference: FlightReference?
        private var configuredBundleURL: URL?

        init() {
            marker.geometry?.firstMaterial?.diffuse.contents = NSColor.systemRed
            scene.rootNode.addChildNode(marker)
            scene.rootNode.addChildNode(verticalLine)
            addCamera()
            addLights()
        }

        func configure(samples: [FlightSample], bundleURL: URL?) {
            guard configuredBundleURL != bundleURL, let first = samples.first else { return }
            configuredBundleURL = bundleURL
            reference = FlightReference(
                latitude: first.latitude,
                longitude: first.longitude,
                cosineLatitude: cos(first.latitude * .pi / 180)
            )

            scene.rootNode.childNode(withName: "trajectory", recursively: false)?
                .removeFromParentNode()
            scene.rootNode.childNode(withName: "shadow", recursively: false)?
                .removeFromParentNode()
            scene.rootNode.childNode(withName: "ground", recursively: false)?
                .removeFromParentNode()

            let strideValue = max(1, samples.count / 8_000)
            let visibleSamples = samples.enumerated().compactMap { index, sample in
                index.isMultiple(of: strideValue) ? sample : nil
            }
            addTrajectory(samples: visibleSamples)
            addGround()
            updateMarker(sample: first)
        }

        func updateMarker(sample: FlightSample) {
            guard let reference else { return }
            let position = position(for: sample, reference: reference)
            marker.position = position
            verticalLine.geometry = lineGeometry(
                from: SCNVector3(position.x, 0, position.z),
                to: position,
                color: .systemPurple
            )
        }

        private func addTrajectory(samples: [FlightSample]) {
            guard let reference, samples.count > 1 else { return }
            var vertices: [SCNVector3] = []
            var colors: [NSColor] = []
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

            let trajectory = lineNode(vertices: vertices, colors: colors)
            trajectory.name = "trajectory"
            scene.rootNode.addChildNode(trajectory)

            let shadowColors = Array(
                repeating: NSColor.brown.withAlphaComponent(0.65),
                count: shadowVertices.count
            )
            let shadow = lineNode(vertices: shadowVertices, colors: shadowColors)
            shadow.name = "shadow"
            scene.rootNode.addChildNode(shadow)
        }

        private func addGround() {
            let floor = SCNFloor()
            floor.reflectivity = 0
            floor.firstMaterial?.diffuse.contents = NSColor.darkGray
            floor.firstMaterial?.roughness.contents = 1
            let node = SCNNode(geometry: floor)
            node.name = "ground"
            scene.rootNode.addChildNode(node)
        }

        private func lineNode(vertices: [SCNVector3], colors: [NSColor]) -> SCNNode {
            let vertexSource = SCNGeometrySource(vertices: vertices)
            let colorComponents: [Float] = colors.flatMap { color in
                let converted = color.usingColorSpace(.deviceRGB) ?? color
                return [
                    Float(converted.redComponent),
                    Float(converted.greenComponent),
                    Float(converted.blueComponent),
                    Float(converted.alphaComponent)
                ]
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
            return SCNNode(geometry: geometry)
        }

        private func lineGeometry(
            from start: SCNVector3,
            to end: SCNVector3,
            color: NSColor
        ) -> SCNGeometry {
            let source = SCNGeometrySource(vertices: [start, end])
            let element = SCNGeometryElement(
                indices: [Int32(0), Int32(1)],
                primitiveType: .line
            )
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = color
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

        private func speedColor(_ speed: Double) -> NSColor {
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
            let node = SCNNode()
            node.camera = camera
            node.position = SCNVector3(4, 3, 6)
            node.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(node)
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

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("Vitesse")
                Spacer()
                Text("\(speed, format: .number.precision(.fractionLength(0))) km/h")
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    LinearGradient(
                        colors: [.blue, .green, .green, .yellow, .red],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 7)
                    Rectangle()
                        .fill(.white)
                        .frame(width: 3, height: 16)
                        .offset(x: min(proxy.size.width - 3, max(0, speed / 400 * proxy.size.width)))
                }
            }
            .frame(height: 16)
        }
        .font(.caption.bold())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FlightPathGScale: View {
    let loadFactor: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Charge")
            Text("\(loadFactor, format: .number.precision(.fractionLength(1))) g")
                .font(.title3.monospacedDigit().bold())
        }
        .foregroundStyle(loadFactor < 0 ? .blue : loadFactor > 2 ? .red : .green)
        .padding(8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FlightPathAltitudeScale: View {
    let altitude: Double
    let maximumAltitude: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("Altitude")
            Text("\(altitude, format: .number.precision(.fractionLength(0))) ft")
                .font(.title3.monospacedDigit().bold())
            ProgressView(value: altitude, total: max(1, maximumAltitude))
                .frame(width: 130)
                .tint(altitude >= 3_000 && altitude <= 5_000 ? .green : .orange)
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }
}
