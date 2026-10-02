import SceneKit
import SwiftUI

struct Aircraft3DView: NSViewRepresentable {
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

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.scene
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.rendersContinuously = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.loadModelIfNeeded(from: modelURL)
        context.coordinator.axes.isHidden = !showsAxes
        context.coordinator.verticalGrid.isHidden = !showsVerticalGrid
        context.coordinator.updateAcceleration(
            x: accelerationX,
            y: accelerationY,
            z: accelerationZ,
            mountingPitch: mountingPitch
        )

        let rawSensorQuaternion = simd_quatf(
            ix: Float(quaternionX),
            iy: Float(quaternionY),
            iz: Float(quaternionZ),
            r: Float(quaternionW)
        )
        let sensorQuaternion = rawSensorQuaternion.normalizedSafely
        let pitchCorrection = simd_quatf(
            angle: Float(-mountingPitch * .pi / 180),
            axis: SIMD3<Float>(1, 0, 0)
        )
        let sensorToAircraftAxes = simd_quatf(
            angle: -.pi / 2,
            axis: SIMD3<Float>(1, 0, 0)
        )
        let inversionCorrection = simd_quatf(
            angle: isInverted ? .pi : 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
        // Python renders (Rx(pitch) * P3 * Ry(inversion) * R(conjugate(q))).T.
        // Transposing reverses the product and each rotation, yielding this order.
        let quaternion = sensorQuaternion
            * inversionCorrection
            * sensorToAircraftAxes
            * pitchCorrection
        context.coordinator.updateFlightVector(
            orientation: quaternion,
            speed: speed
        )
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.05
        context.coordinator.aircraft.simdOrientation = quaternion
        SCNTransaction.commit()
    }

    final class Coordinator {
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

        init() {
            configureScene()
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
            scene.rootNode.addChildNode(aircraft)
            aircraft.addChildNode(modelRoot)
            let fallbackModel = SCNNode()
            fallbackModel.simdOrientation = simd_quatf(
                angle: .pi / 2,
                axis: SIMD3<Float>(1, 0, 0)
            )
            fallbackModel.addChildNode(makeFuselage())
            fallbackModel.addChildNode(makeWing())
            fallbackModel.addChildNode(makeTail())
            fallbackModel.addChildNode(makeNose())
            modelRoot.addChildNode(fallbackModel)
            scene.rootNode.addChildNode(makeGroundGrid())
            configureAxes()
            configureVerticalGrid()
            aircraft.addChildNode(axes)
            scene.rootNode.addChildNode(verticalGrid)
            aircraft.addChildNode(accelerationVector)
            aircraft.addChildNode(accelerationTrail)
            scene.rootNode.addChildNode(velocityVector)
            scene.rootNode.addChildNode(noseTrail)
            scene.rootNode.addChildNode(makeCamera())
            scene.rootNode.addChildNode(makeLight())
            scene.rootNode.addChildNode(makeAmbientLight())
        }

        private func makeFuselage() -> SCNNode {
            let geometry = SCNCapsule(capRadius: 0.22, height: 2.8)
            geometry.firstMaterial?.diffuse.contents = NSColor.systemRed
            geometry.firstMaterial?.metalness.contents = 0.25
            geometry.firstMaterial?.roughness.contents = 0.42
            let node = SCNNode(geometry: geometry)
            node.eulerAngles.x = .pi / 2
            return node
        }

        private func makeWing() -> SCNNode {
            let geometry = SCNBox(width: 4.2, height: 0.08, length: 0.75, chamferRadius: 0.08)
            geometry.firstMaterial?.diffuse.contents = NSColor.white
            let node = SCNNode(geometry: geometry)
            node.position.z = 0.1
            return node
        }

        private func makeTail() -> SCNNode {
            let horizontal = SCNNode(
                geometry: SCNBox(width: 1.55, height: 0.06, length: 0.45, chamferRadius: 0.04)
            )
            horizontal.geometry?.firstMaterial?.diffuse.contents = NSColor.white
            horizontal.position.z = 1.05

            let vertical = SCNNode(
                geometry: SCNBox(width: 0.06, height: 0.72, length: 0.42, chamferRadius: 0.03)
            )
            vertical.geometry?.firstMaterial?.diffuse.contents = NSColor.systemRed
            vertical.position = SCNVector3(0, 0.34, 1.05)

            let tail = SCNNode()
            tail.addChildNode(horizontal)
            tail.addChildNode(vertical)
            return tail
        }

        private func makeNose() -> SCNNode {
            let geometry = SCNCone(topRadius: 0, bottomRadius: 0.22, height: 0.65)
            geometry.firstMaterial?.diffuse.contents = NSColor.darkGray
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
            let color: NSColor
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
            let color: NSColor
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
            color: NSColor
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
            axes.isHidden = true
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
            color: NSColor
        ) -> SCNNode {
            let node = line(from: start, to: end)
            node.geometry?.firstMaterial?.diffuse.contents = color
            return node
        }

        private func makeGroundGrid() -> SCNNode {
            let node = SCNNode()
            for value in stride(from: -10, through: 10, by: 1) {
                let horizontal = line(
                    from: SCNVector3(-10, -2, Float(value)),
                    to: SCNVector3(10, -2, Float(value))
                )
                let vertical = line(
                    from: SCNVector3(Float(value), -2, -10),
                    to: SCNVector3(Float(value), -2, 10)
                )
                node.addChildNode(horizontal)
                node.addChildNode(vertical)
            }
            return node
        }

        private func line(from start: SCNVector3, to end: SCNVector3) -> SCNNode {
            let source = SCNGeometrySource(vertices: [start, end])
            let element = SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)
            let geometry = SCNGeometry(sources: [source], elements: [element])
            geometry.firstMaterial?.diffuse.contents = NSColor.systemGreen.withAlphaComponent(0.35)
            return SCNNode(geometry: geometry)
        }

        private func makeCamera() -> SCNNode {
            let camera = SCNCamera()
            camera.fieldOfView = 48
            camera.zNear = 0.1
            camera.zFar = 100
            let node = SCNNode()
            node.camera = camera
            node.position = SCNVector3(5.5, 3.7, 6.5)
            node.look(at: SCNVector3Zero)
            return node
        }

        private func makeLight() -> SCNNode {
            let light = SCNLight()
            light.type = .directional
            light.intensity = 1_300
            let node = SCNNode()
            node.light = light
            node.eulerAngles = SCNVector3(-0.8, 0.6, 0)
            return node
        }

        private func makeAmbientLight() -> SCNNode {
            let light = SCNLight()
            light.type = .ambient
            light.intensity = 450
            light.color = NSColor.white
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
