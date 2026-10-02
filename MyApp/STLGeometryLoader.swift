import Foundation
import SceneKit

enum STLGeometryLoader {
    nonisolated static func load(from url: URL) throws -> SCNGeometry {
        let data = try Data(contentsOf: url)
        let vertices: [SCNVector3]

        if isBinarySTL(data) {
            vertices = try binaryVertices(from: data)
        } else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw STLLoadingError.invalidFormat
            }
            vertices = asciiVertices(from: text)
        }

        guard vertices.count >= 3 else { throw STLLoadingError.noTriangles }
        return makeGeometry(vertices: normalized(vertices))
    }

    nonisolated private static func isBinarySTL(_ data: Data) -> Bool {
        guard data.count >= 84 else { return false }
        let triangleCount = Int(readUInt32(data, at: 80))
        return 84 + triangleCount * 50 == data.count
    }

    nonisolated private static func binaryVertices(from data: Data) throws -> [SCNVector3] {
        let count = Int(readUInt32(data, at: 80))
        guard 84 + count * 50 <= data.count else { throw STLLoadingError.invalidFormat }

        var result: [SCNVector3] = []
        result.reserveCapacity(count * 3)
        for triangle in 0..<count {
            let base = 84 + triangle * 50 + 12
            for vertex in 0..<3 {
                let offset = base + vertex * 12
                result.append(
                    SCNVector3(
                        readFloat(data, at: offset),
                        readFloat(data, at: offset + 4),
                        readFloat(data, at: offset + 8)
                    )
                )
            }
        }
        return result
    }

    nonisolated private static func asciiVertices(from text: String) -> [SCNVector3] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 4, parts[0].lowercased() == "vertex",
                  let x = Float(parts[1]),
                  let y = Float(parts[2]),
                  let z = Float(parts[3]) else {
                return nil
            }
            return SCNVector3(x, y, z)
        }
    }

    nonisolated private static func normalized(_ vertices: [SCNVector3]) -> [SCNVector3] {
        guard let first = vertices.first else { return vertices }
        var minimum = first
        var maximum = first
        for vertex in vertices.dropFirst() {
            minimum.x = min(minimum.x, vertex.x)
            minimum.y = min(minimum.y, vertex.y)
            minimum.z = min(minimum.z, vertex.z)
            maximum.x = max(maximum.x, vertex.x)
            maximum.y = max(maximum.y, vertex.y)
            maximum.z = max(maximum.z, vertex.z)
        }

        let center = SCNVector3(
            (minimum.x + maximum.x) / 2,
            (minimum.y + maximum.y) / 2,
            (minimum.z + maximum.z) / 2
        )
        let largestDimension = max(
            maximum.x - minimum.x,
            maximum.y - minimum.y,
            maximum.z - minimum.z
        )
        let scale: CGFloat = largestDimension > 0 ? 4.2 / largestDimension : 1
        return vertices.map { vertex in
            let x = (vertex.x - center.x) * scale
            let y = (vertex.y - center.y) * scale
            let z = (vertex.z - center.z) * scale
            return SCNVector3(x, y, z)
        }
    }

    nonisolated private static func makeGeometry(vertices: [SCNVector3]) -> SCNGeometry {
        var normals: [SCNVector3] = []
        normals.reserveCapacity(vertices.count)
        for index in stride(from: 0, to: vertices.count - 2, by: 3) {
            let first = vertices[index]
            let second = vertices[index + 1]
            let third = vertices[index + 2]
            let normal = normalizedCross(
                SCNVector3(second.x - first.x, second.y - first.y, second.z - first.z),
                SCNVector3(third.x - first.x, third.y - first.y, third.z - first.z)
            )
            normals.append(contentsOf: [normal, normal, normal])
        }

        let source = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let indices = vertices.indices.map(UInt32.init)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geometry = SCNGeometry(sources: [source, normalSource], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor.white
        material.metalness.contents = 0.18
        material.roughness.contents = 0.5
        material.isDoubleSided = true
        geometry.materials = [material]
        return geometry
    }

    nonisolated private static func normalizedCross(
        _ lhs: SCNVector3,
        _ rhs: SCNVector3
    ) -> SCNVector3 {
        let cross = SCNVector3(
            lhs.y * rhs.z - lhs.z * rhs.y,
            lhs.z * rhs.x - lhs.x * rhs.z,
            lhs.x * rhs.y - lhs.y * rhs.x
        )
        let length = sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
        guard length > 0.000_001 else { return SCNVector3(0, 1, 0) }
        return SCNVector3(cross.x / length, cross.y / length, cross.z / length)
    }

    nonisolated private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    nonisolated private static func readFloat(_ data: Data, at offset: Int) -> Float {
        Float(bitPattern: readUInt32(data, at: offset))
    }
}

enum STLLoadingError: LocalizedError {
    case invalidFormat
    case noTriangles

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Le fichier STL n’est pas valide."
        case .noTriangles:
            return "Le fichier STL ne contient aucun triangle."
        }
    }
}
