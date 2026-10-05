import AVFoundation
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

struct Aircraft3DView: PlatformViewRepresentable {
    let quaternionW: Double
    let quaternionX: Double
    let quaternionY: Double
    let quaternionZ: Double
    let modelURL: URL?
    let mountingPitch: Double
    let isInverted: Bool
    let showsAxes: Bool
    let showsVerticalGrid: Bool
    let accelerationX: Double
    let accelerationY: Double
    let accelerationZ: Double
    let speed: Double
    let samples: [FlightSample]
    let player: AVPlayer

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
        view.backgroundColor = PlatformColor(
            red: 0.12,
            green: 0.20,
            blue: 0.31,
            alpha: 1
        )
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
        view.isPlaying = true
        view.rendersContinuously = true
        view.defaultCameraController.target = SCNVector3Zero
        return view
    }

    private func updateView(_ view: SCNView, context: Context) {
        context.coordinator.configureRealtimeUpdates(
            samples: samples,
            player: player,
            mountingPitch: mountingPitch,
            isInverted: isInverted
        )
        context.coordinator.loadModelIfNeeded(from: modelURL)
        context.coordinator.axes.isHidden = !showsAxes
        context.coordinator.verticalGrid.isHidden = !showsVerticalGrid
        if samples.isEmpty {
            context.coordinator.updateAircraft(
                quaternionW: quaternionW,
                quaternionX: quaternionX,
                quaternionY: quaternionY,
                quaternionZ: quaternionZ,
                speed: speed,
                mountingPitch: mountingPitch,
                isInverted: isInverted,
                updatesFlightVector: false
            )
        }
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let scene = SCNScene()
        let aircraft = SCNNode()
        private let modelRoot = SCNNode()
        let axes = SCNNode()
        let verticalGrid = SCNNode()
        private let accelerationVector = SCNNode()
        private let accelerationTrail = SCNNode()
        private let velocityVector = SCNNode()
        private let noseTrail = SCNNode()
        private var trailPoints: [SCNVector3] = []
        private var noseTrailPoints: [SCNVector3] = []
        private var currentModelURL: URL?
        private var realtimeSamples: [FlightSample] = []
        private weak var player: AVPlayer?
        private var realtimeMountingPitch = 15.0
        private var realtimeIsInverted = false
        private let realtimeLock = NSLock()

        override init() {
            super.init()
            configureScene()
        }

        func configureRealtimeUpdates(
            samples: [FlightSample],
            player: AVPlayer,
            mountingPitch: Double,
            isInverted: Bool
        ) {
            realtimeLock.lock()
            defer { realtimeLock.unlock() }
            realtimeMountingPitch = mountingPitch
            realtimeIsInverted = isInverted

            let needsRestart = self.player !== player
                || realtimeSamples.count != samples.count
                || realtimeSamples.first?.timestamp != samples.first?.timestamp
                || realtimeSamples.last?.timestamp != samples.last?.timestamp
            guard needsRestart else { return }

            self.player = player
            realtimeSamples = samples
        }

        func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
            updateFromPlaybackClock()
        }

        func updateAircraft(
            quaternionW: Double,
            quaternionX: Double,
            quaternionY: Double,
            quaternionZ: Double,
            speed: Double,
            mountingPitch: Double? = nil,
            isInverted: Bool? = nil,
            updatesFlightVector: Bool = true
        ) {
            let rawSensorQuaternion = simd_quatf(
                ix: Float(quaternionX),
                iy: Float(quaternionY),
                iz: Float(quaternionZ),
                r: Float(quaternionW)
            )
            let sensorQuaternion = rawSensorQuaternion.normalizedSafely
            let pitchCorrection = simd_quatf(
                angle: Float(-(mountingPitch ?? realtimeMountingPitch) * .pi / 180),
                axis: SIMD3<Float>(1, 0, 0)
            )
            let sensorToAircraftAxes = simd_quatf(
                angle: -.pi / 2,
                axis: SIMD3<Float>(1, 0, 0)
            )
            let inversionCorrection = simd_quatf(
                angle: (isInverted ?? realtimeIsInverted) ? .pi : 0,
                axis: SIMD3<Float>(0, 1, 0)
            )
            let orientation = sensorQuaternion
                * inversionCorrection
                * sensorToAircraftAxes
                * pitchCorrection
            let zUpToYUp = simd_quatf(
                angle: -.pi / 2,
                axis: SIMD3<Float>(1, 0, 0)
            )
            let sceneOrientation = zUpToYUp * orientation * zUpToYUp.inverse
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            if updatesFlightVector {
                updateFlightVector(orientation: sceneOrientation, speed: speed)
            }
            aircraft.simdOrientation = sceneOrientation
            SCNTransaction.commit()
        }

        private func updateFromPlaybackClock() {
            realtimeLock.lock()
            let samples = realtimeSamples
            let player = player
            let mountingPitch = realtimeMountingPitch
            let isInverted = realtimeIsInverted
            realtimeLock.unlock()

            guard let player, !samples.isEmpty else { return }
            let seconds = player.currentTime().seconds
            guard seconds.isFinite else { return }
            let sample = samples[sampleIndex(at: seconds, in: samples)]
            updateAircraft(
                quaternionW: sample.quaternionW,
                quaternionX: sample.quaternionX,
                quaternionY: sample.quaternionY,
                quaternionZ: sample.quaternionZ,
                speed: sample.speed,
                mountingPitch: mountingPitch,
                isInverted: isInverted,
                updatesFlightVector: false
            )
        }

        private func sampleIndex(at time: TimeInterval, in samples: [FlightSample]) -> Int {
            var lower = 0
            var upper = samples.count
            while lower < upper {
                let middle = (lower + upper) / 2
                if samples[middle].elapsed < time {
                    lower = middle + 1
                } else {
                    upper = middle
                }
            }
            guard lower > 0 else { return 0 }
            guard lower < samples.count else { return samples.count - 1 }
            let before = samples[lower - 1]
            let after = samples[lower]
            return time - before.elapsed <= after.elapsed - time ? lower - 1 : lower
        }

        func loadModelIfNeeded(from url: URL?) {
            guard let url, url != currentModelURL else { return }
            do {
                let geometry = try STLGeometryLoader.load(from: url)
                let model = SCNNode(geometry: geometry)
                let stlZCorrection = simd_quatf(
                    angle: .pi,
                    axis: SIMD3<Float>(0, 0, 1)
                )
                let stlTiltCorrection = simd_quatf(
                    angle: Float(5 * Double.pi / 180),
                    axis: SIMD3<Float>(1, 0, 0)
                )
                model.simdOrientation = stlZCorrection * stlTiltCorrection
                modelRoot.childNodes.forEach { $0.removeFromParentNode() }
                modelRoot.addChildNode(model)
                currentModelURL = url
            } catch {
                return
            }
        }

        private func configureScene() {
            scene.background.contents = PlatformColor(
                red: 0.12,
                green: 0.20,
                blue: 0.31,
                alpha: 1
            )
            scene.fogColor = PlatformColor(
                red: 0.35,
                green: 0.48,
                blue: 0.60,
                alpha: 1
            )
            scene.fogStartDistance = 14
            scene.fogEndDistance = 34
            scene.fogDensityExponent = 1.2

            aircraft.simdPosition = SIMD3<Float>(0, 0.8, 0)
            modelRoot.simdPosition = SIMD3<Float>(0, 0, 0)
            modelRoot.simdOrientation = simd_quatf(
                angle: -.pi / 2,
                axis: SIMD3<Float>(1, 0, 0)
            )
            scene.rootNode.addChildNode(aircraft)
            aircraft.addChildNode(modelRoot)
            let fallbackModel = SCNNode()
            fallbackModel.simdOrientation = simd_quatf(
                angle: .pi,
                axis: SIMD3<Float>(1, 0, 0)
            )
            fallbackModel.addChildNode(makeFuselage())
            fallbackModel.addChildNode(makeWing())
            fallbackModel.addChildNode(makeTail())
            fallbackModel.addChildNode(makeNose())
            modelRoot.addChildNode(fallbackModel)
            configureAxes()
            configureVerticalGrid()
            scene.rootNode.addChildNode(axes)
            scene.rootNode.addChildNode(verticalGrid)
            scene.rootNode.addChildNode(makeGround())
            scene.rootNode.addChildNode(makeGroundGrid())
            scene.rootNode.addChildNode(makeCamera())
            scene.rootNode.addChildNode(makeLight())
            scene.rootNode.addChildNode(makeFillLight())
            scene.rootNode.addChildNode(makeAmbientLight())
        }

        private func makeFuselage() -> SCNNode {
            let geometry = SCNCapsule(capRadius: 0.22, height: 2.8)
            geometry.firstMaterial?.diffuse.contents = PlatformColor.systemRed
            geometry.firstMaterial?.metalness.contents = 0.25
            geometry.firstMaterial?.roughness.contents = 0.42
            let node = SCNNode(geometry: geometry)
            node.eulerAngles.x = .pi / 2
            return node
        }

        private func makeWing() -> SCNNode {
            let geometry = SCNBox(width: 4.2, height: 0.08, length: 0.75, chamferRadius: 0.08)
            geometry.firstMaterial?.diffuse.contents = PlatformColor.white
            let node = SCNNode(geometry: geometry)
            node.position.z = 0.1
            return node
        }

        private func makeTail() -> SCNNode {
            let horizontal = SCNNode(
                geometry: SCNBox(width: 1.55, height: 0.06, length: 0.45, chamferRadius: 0.04)
            )
            horizontal.geometry?.firstMaterial?.diffuse.contents = PlatformColor.white
            horizontal.position.z = 1.05

            let vertical = SCNNode(
                geometry: SCNBox(width: 0.06, height: 0.72, length: 0.42, chamferRadius: 0.03)
            )
            vertical.geometry?.firstMaterial?.diffuse.contents = PlatformColor.systemRed
            vertical.position = SCNVector3(0, 0.34, 1.05)

            let tail = SCNNode()
            tail.addChildNode(horizontal)
            tail.addChildNode(vertical)
            return tail
        }

        private func makeNose() -> SCNNode {
            let geometry = SCNCone(topRadius: 0, bottomRadius: 0.22, height: 0.65)
            geometry.firstMaterial?.diffuse.contents = PlatformColor.darkGray
            let node = SCNNode(geometry: geometry)
            node.eulerAngles.x = -.pi / 2
            node.position.z = -1.65
            return node
        }

        func updateFlightVector(
            orientation: simd_quatf,
            speed: Double
        ) {
            let forward = orientation.act(SIMD3<Float>(0, 1, 0))
            let length = Float(max(0.8, min(4.5, speed / 80)))
            let endpoint = SCNVector3(
                forward.x * length,
                forward.y * length,
                forward.z * length
            )
            let color: PlatformColor
            switch speed {
            case ..<113:
                color = .systemBlue
            case ..<236:
                color = .systemGreen
            case ..<300:
                color = .systemYellow
            default:
                color = .systemRed
            }

            velocityVector.geometry = line(
                from: SCNVector3Zero,
                to: endpoint
            ).geometry
            velocityVector.geometry?.firstMaterial?.diffuse.contents = color

            noseTrailPoints.append(endpoint)
            if noseTrailPoints.count > 40 {
                noseTrailPoints.removeFirst(noseTrailPoints.count - 40)
            }
            noseTrail.geometry = trailGeometry(
                points: noseTrailPoints,
                color: color.withAlphaComponent(0.55)
            )
        }

        func updateAcceleration(
            x: Double,
            y: Double,
            z: Double,
            mountingPitch: Double
        ) {
            let angle = mountingPitch * .pi / 180
            let permuted = SIMD3<Double>(-x, z, -y)
            let transformed = SIMD3<Double>(
                permuted.x,
                cos(angle) * permuted.y - sin(angle) * permuted.z,
                sin(angle) * permuted.y + cos(angle) * permuted.z
            )
            let magnitude = simd_length(transformed)
            guard magnitude.isFinite, magnitude > 0.000_001 else { return }

            let direction = transformed / magnitude
            let length = min(4.5, magnitude / 9.80665 * 1.5)
            let endpoint = SCNVector3(
                direction.x * length,
                direction.y * length,
                direction.z * length
            )
            let loadFactor = magnitude / 9.80665
            let color: PlatformColor
            if transformed.z > 0 {
                color = .systemBlue
            } else if loadFactor > 2 {
                color = .systemRed
            } else {
                color = .systemGreen
            }

            accelerationVector.geometry = line(
                from: SCNVector3Zero,
                to: endpoint
            ).geometry
            accelerationVector.geometry?.firstMaterial?.diffuse.contents = color

            trailPoints.append(endpoint)
            if trailPoints.count > 40 {
                trailPoints.removeFirst(trailPoints.count - 40)
            }
            accelerationTrail.geometry = trailGeometry(
                points: trailPoints,
                color: color.withAlphaComponent(0.55)
            )
        }

        private func trailGeometry(
            points: [SCNVector3],
            color: PlatformColor
        ) -> SCNGeometry? {
            guard points.count > 1 else { return nil }
            var vertices: [SCNVector3] = []
            for index in 1..<points.count {
                vertices.append(points[index - 1])
                vertices.append(points[index])
            }
            let source = SCNGeometrySource(vertices: vertices)
            let indices = vertices.indices.map(Int32.init)
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = color
            return geometry
        }

        private func configureAxes() {
            axes.addChildNode(
                coloredLine(
                    from: SCNVector3Zero,
                    to: SCNVector3(3, 0, 0),
                    color: .systemRed
                )
            )
            axes.addChildNode(
                coloredLine(
                    from: SCNVector3Zero,
                    to: SCNVector3(0, 3, 0),
                    color: .systemGreen
                )
            )
            axes.addChildNode(
                coloredLine(
                    from: SCNVector3Zero,
                    to: SCNVector3(0, 0, 3),
                    color: .systemBlue
                )
            )
            axes.addChildNode(axisLabel("X", color: .systemRed, position: SCNVector3(3.15, 0, 0)))
            axes.addChildNode(axisLabel("Y", color: .systemGreen, position: SCNVector3(0, 3.15, 0)))
            axes.addChildNode(axisLabel("Z", color: .systemBlue, position: SCNVector3(0, 0, 3.15)))
            axes.isHidden = true
        }

        private func axisLabel(_ text: String, color: PlatformColor, position: SCNVector3) -> SCNNode {
            let geometry = SCNText(string: text, extrusionDepth: 0.04)
            geometry.font = .boldSystemFont(ofSize: 12)
            geometry.flatness = 0.2
            geometry.firstMaterial?.diffuse.contents = color
            geometry.firstMaterial?.lightingModel = .constant

            let node = SCNNode(geometry: geometry)
            node.position = position
            node.scale = SCNVector3(0.035, 0.035, 0.035)
            node.constraints = [SCNBillboardConstraint()]
            return node
        }

        private func configureVerticalGrid() {
            for value in stride(from: -10, through: 10, by: 1) {
                verticalGrid.addChildNode(
                    line(
                        from: SCNVector3(Float(value), -10, 4),
                        to: SCNVector3(Float(value), 10, 4)
                    )
                )
                verticalGrid.addChildNode(
                    line(
                        from: SCNVector3(-10, Float(value), 4),
                        to: SCNVector3(10, Float(value), 4)
                    )
                )
            }
            verticalGrid.isHidden = true
        }

        private func coloredLine(
            from start: SCNVector3,
            to end: SCNVector3,
            color: PlatformColor
        ) -> SCNNode {
            let node = line(from: start, to: end)
            node.geometry?.firstMaterial?.diffuse.contents = color
            return node
        }

        private func makeGroundGrid() -> SCNNode {
            let node = SCNNode()
            for value in stride(from: -10, through: 10, by: 1) {
                let horizontal = line(
                    from: SCNVector3(-10, -1.98, Float(value)),
                    to: SCNVector3(10, -1.98, Float(value))
                )
                let vertical = line(
                    from: SCNVector3(Float(value), -1.98, -10),
                    to: SCNVector3(Float(value), -1.98, 10)
                )
                node.addChildNode(horizontal)
                node.addChildNode(vertical)
            }
            return node
        }

        private func makeGround() -> SCNNode {
            let floor = SCNFloor()
            floor.reflectivity = 0.06
            floor.reflectionFalloffEnd = 7
            floor.firstMaterial?.lightingModel = .physicallyBased
            floor.firstMaterial?.diffuse.contents = PlatformColor(
                red: 0.055,
                green: 0.09,
                blue: 0.14,
                alpha: 1
            )
            floor.firstMaterial?.roughness.contents = 0.82

            let node = SCNNode(geometry: floor)
            node.position.y = -2
            node.castsShadow = false
            return node
        }

        private func line(from start: SCNVector3, to end: SCNVector3) -> SCNNode {
            let source = SCNGeometrySource(vertices: [start, end])
            let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = PlatformColor.systemTeal.withAlphaComponent(0.28)
            geometry.firstMaterial?.lightingModel = .constant
            return SCNNode(geometry: geometry)
        }

        private func makeCamera() -> SCNNode {
            let camera = SCNCamera()
            camera.fieldOfView = 44
            camera.zNear = 0.1
            camera.zFar = 80
            camera.wantsHDR = true
            camera.screenSpaceAmbientOcclusionIntensity = 0.65
            camera.screenSpaceAmbientOcclusionRadius = 4
            let node = SCNNode()
            node.camera = camera
            node.simdPosition = SIMD3<Float>(7.2, 4.2, 5.4)
            node.look(at: SCNVector3(0, 0.4, 0))
            return node
        }

        private func makeLight() -> SCNNode {
            let light = SCNLight()
            light.type = .directional
            light.intensity = 1_650
            light.color = PlatformColor(
                red: 1,
                green: 0.96,
                blue: 0.90,
                alpha: 1
            )
            light.castsShadow = true
            light.shadowColor = PlatformColor.black.withAlphaComponent(0.32)
            light.shadowRadius = 6
            light.shadowSampleCount = 16
            let node = SCNNode()
            node.light = light
            node.eulerAngles = SCNVector3(-0.75, 0.65, -0.25)
            return node
        }

        private func makeFillLight() -> SCNNode {
            let light = SCNLight()
            light.type = .directional
            light.intensity = 520
            light.color = PlatformColor(
                red: 0.72,
                green: 0.82,
                blue: 1,
                alpha: 1
            )
            let node = SCNNode()
            node.light = light
            node.eulerAngles = SCNVector3(0.45, -1.05, 0.35)
            return node
        }

        private func makeAmbientLight() -> SCNNode {
            let light = SCNLight()
            light.type = .ambient
            light.intensity = 190
            light.color = PlatformColor.white
            let node = SCNNode()
            node.light = light
            return node
        }
    }
}

private extension simd_quatf {
    var normalizedSafely: simd_quatf {
        let magnitude = simd_length(vector)
        guard magnitude.isFinite, magnitude > 0.000_001 else {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(1, 0, 0))
        }
        return simd_quatf(vector: vector / magnitude)
    }
}
