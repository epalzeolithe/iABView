import Foundation
import CoreLocation
import simd

struct FlightSample: Identifiable, Sendable {
    let id: Int
    let timestamp: Date
    let elapsed: TimeInterval
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let speed: Double
    let heading: Double
    let verticalSpeed: Double
    let indicatedAirspeed: Double
    let windSpeed: Double
    let windDirection: Double
    let accelerationX: Double
    let accelerationY: Double
    let accelerationZ: Double
    let quaternionW: Double
    let quaternionX: Double
    let quaternionY: Double
    let quaternionZ: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var headwind: Double {
        let relativeAngle = (heading - windDirection) * .pi / 180
        return -(windSpeed / 1.852) * cos(relativeAngle)
    }

    var crosswind: Double {
        let relativeAngle = (heading - windDirection) * .pi / 180
        return (windSpeed / 1.852) * sin(relativeAngle)
    }

    var energy: Double {
        0.5 * speed * speed + 9.81 * altitude * 0.3048
    }

    nonisolated var loadFactor: Double {
        let magnitude = sqrt(
            accelerationX * accelerationX
                + accelerationY * accelerationY
                + accelerationZ * accelerationZ
        )
        return magnitude / 9.80665
    }

    nonisolated func signedLoadFactor(mountingPitch: Double) -> Double {
        let angle = mountingPitch * .pi / 180
        let permutedY = accelerationZ
        let permutedZ = -accelerationY
        let transformedZ = sin(angle) * permutedY + cos(angle) * permutedZ
        return transformedZ > 0 ? -loadFactor : loadFactor
    }

    nonisolated var attitude: Attitude {
        attitude(mountingPitch: 15, isInverted: false)
    }

    nonisolated func attitude(mountingPitch: Double, isInverted: Bool) -> Attitude {
        var sensor = simd_quatd(
            ix: quaternionX,
            iy: quaternionY,
            iz: quaternionZ,
            r: quaternionW
        )
        let magnitude = simd_length(sensor.vector)
        if magnitude.isFinite, magnitude > 0.000_001 {
            sensor = simd_quatd(vector: sensor.vector / magnitude)
        } else {
            sensor = simd_quatd(angle: 0, axis: SIMD3<Double>(1, 0, 0))
        }

        let inversion = simd_quatd(
            angle: isInverted ? .pi : 0,
            axis: SIMD3<Double>(0, 1, 0)
        )
        let axisCorrection = simd_quatd(angle: -.pi / 2, axis: SIMD3<Double>(1, 0, 0))
        let mountingCorrection = simd_quatd(
            angle: -mountingPitch * .pi / 180,
            axis: SIMD3<Double>(1, 0, 0)
        )
        let orientation = sensor * inversion * axisCorrection * mountingCorrection
        let forward = orientation.act(SIMD3<Double>(0, 1, 0))
        let up = orientation.act(SIMD3<Double>(0, 0, 1))
        let pitch = asin(max(-1, min(1, forward.z))) * 180 / .pi
        let worldUp = SIMD3<Double>(0, 0, 1)
        let projectedUp = simd_cross(forward, simd_cross(worldUp, forward))
        let projectedLength = simd_length(projectedUp)
        guard projectedLength > 0.000_001 else {
            return Attitude(roll: 0, pitch: pitch)
        }
        let referenceUp = projectedUp / projectedLength
        let inclination = atan2(
            simd_dot(simd_cross(up, referenceUp), forward),
            simd_dot(up, referenceUp)
        )
        return Attitude(roll: -inclination * 180 / .pi, pitch: pitch)
    }
}

struct Attitude: Sendable {
    let roll: Double
    let pitch: Double

    nonisolated init(roll: Double, pitch: Double) {
        self.roll = roll
        self.pitch = pitch
    }
}

struct FlightBookmark: Identifiable, Sendable {
    let id: UUID
    let name: String
    let frame: Int
    let displayTime: String

    nonisolated init(id: UUID = UUID(), name: String, frame: Int, displayTime: String) {
        self.id = id
        self.name = name
        self.frame = frame
        self.displayTime = displayTime
    }
}

struct METARReading: Sendable {
    let date: Date
    let report: String
}

enum FigureKind: String, Sendable {
    case loop = "Looping"
    case roll = "Tonneau"
    case hammerhead = "Renversement"
    case immelmann = "Immelmann"
    case spin = "Vrille"
}

struct FlightFigure: Identifiable, Sendable {
    let kind: FigureKind
    let startIndex: Int
    let endIndex: Int
    let startTime: TimeInterval
    let endTime: TimeInterval

    var id: String { "\(kind.rawValue)-\(startIndex)-\(endIndex)" }
    var duration: TimeInterval { max(0, endTime - startTime) }
}

struct FlightBundle: Sendable {
    let url: URL
    let samples: [FlightSample]
    let bookmarks: [FlightBookmark]
    let metar: [METARReading]
    let figures: [FlightFigure]
}

enum FlightLoadError: LocalizedError {
    case missingFile(String)
    case emptyData
    case invalidCSV

    var errorDescription: String? {
        switch self {
        case .missingFile(let name):
            return "Le fichier \(name) est absent du bundle."
        case .emptyData:
            return "Le fichier merged_data.csv ne contient aucune donnée."
        case .invalidCSV:
            return "Le format de merged_data.csv n’est pas reconnu."
        }
    }
}

enum FlightBundleLoader {
    nonisolated static func load(from url: URL) throws -> FlightBundle {
        let csvURL = url.appendingPathComponent("merged_data.csv")
        guard FileManager.default.fileExists(atPath: csvURL.path) else {
            throw FlightLoadError.missingFile("merged_data.csv")
        }

        let csv = try String(contentsOf: csvURL, encoding: .utf8)
        var rows = CSVParser.rows(in: csv)
        guard let headers = rows.first else { throw FlightLoadError.invalidCSV }
        rows.removeFirst()

        let columns = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })
        func value(_ name: String, in row: [String]) -> String {
            guard let index = columns[name], row.indices.contains(index) else { return "" }
            return row[index]
        }
        func number(_ name: String, in row: [String]) -> Double {
            Double(value(name, in: row)) ?? 0
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS"

        guard let firstTimestamp = rows.lazy.compactMap({
            formatter.date(from: value("timestamp", in: $0))
        }).first else {
            throw FlightLoadError.emptyData
        }

        let samples = rows.enumerated().compactMap { offset, row -> FlightSample? in
            guard let timestamp = formatter.date(from: value("timestamp", in: row)) else { return nil }
            return FlightSample(
                id: Int(row.first ?? "") ?? offset,
                timestamp: timestamp,
                elapsed: max(0, timestamp.timeIntervalSince(firstTimestamp)),
                latitude: number("gps_lat", in: row),
                longitude: number("gps_lon", in: row),
                altitude: number("gps_alt", in: row),
                speed: number("gps_speed", in: row),
                heading: number("gps_heading", in: row),
                verticalSpeed: number("gps_fpm", in: row),
                indicatedAirspeed: number("gps_ias", in: row),
                windSpeed: number("era5_wind_speed", in: row),
                windDirection: number("era5_wind_direction", in: row),
                accelerationX: number("x4_acc_x", in: row),
                accelerationY: number("x4_acc_y", in: row),
                accelerationZ: number("x4_acc_z", in: row),
                quaternionW: number("x4_quat_w", in: row),
                quaternionX: number("x4_quat_x", in: row),
                quaternionY: number("x4_quat_y", in: row),
                quaternionZ: number("x4_quat_z", in: row)
            )
        }

        guard !samples.isEmpty else { throw FlightLoadError.emptyData }
        return FlightBundle(
            url: url,
            samples: samples,
            bookmarks: loadBookmarks(from: url.appendingPathComponent("bookmark.csv")),
            metar: loadMETAR(from: url.appendingPathComponent("metar.csv")),
            figures: FlightAnalyzer.detectFigures(in: samples)
        )
    }

    nonisolated static func loadBookmarks(from url: URL) -> [FlightBookmark] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return CSVParser.rows(in: text).dropFirst().compactMap { row in
            guard row.count >= 3, let frame = Int(row[2]) else { return nil }
            return FlightBookmark(name: row[1], frame: frame, displayTime: row[0])
        }
    }

    nonisolated private static func loadMETAR(from url: URL) -> [METARReading] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return CSVParser.rows(in: text).dropFirst().compactMap { row in
            guard row.count >= 2, let date = formatter.date(from: row[0]) else { return nil }
            return METARReading(date: date, report: row[1])
        }
    }
}

enum FlightAnalyzer {
    nonisolated static func detectFigures(
        in samples: [FlightSample],
        mountingPitch: Double = 15,
        isInverted: Bool = false
    ) -> [FlightFigure] {
        guard samples.count > 2 else { return [] }

        var figures: [FlightFigure] = []
        let attitudes = samples.map {
            $0.attitude(mountingPitch: mountingPitch, isInverted: isInverted)
        }
        appendRuns(
            kind: .loop,
            minimumLength: 20,
            samples: samples,
            matches: { index, values in
                abs(attitudes[index].pitch) > 80 && values[index].loadFactor > 1.5
            },
            to: &figures
        )
        appendRuns(
            kind: .roll,
            minimumLength: 20,
            samples: samples,
            matches: { index, values in
                guard index > 0 else { return false }
                let bankDelta = angleDelta(
                    attitudes[index].roll,
                    attitudes[index - 1].roll
                )
                return abs(bankDelta) > 5 && abs(attitudes[index].pitch) < 60
            },
            to: &figures
        )
        appendRuns(
            kind: .hammerhead,
            minimumLength: 10,
            samples: samples,
            matches: { index, values in
                guard index > 0 else { return false }
                return attitudes[index].pitch > 70
                    && values[index].speed < 120
                    && abs(angleDelta(values[index].heading, values[index - 1].heading)) > 20
            },
            to: &figures
        )
        appendRuns(
            kind: .immelmann,
            minimumLength: 20,
            samples: samples,
            matches: { index, values in
                guard index > 0 else { return false }
                return attitudes[index].pitch > 60
                    && abs(angleDelta(
                        attitudes[index].roll,
                        attitudes[index - 1].roll
                    )) > 20
                    && abs(angleDelta(
                        values[index].heading,
                        values[index - 1].heading
                    )) < 5
            },
            to: &figures
        )
        appendRuns(
            kind: .spin,
            minimumLength: 15,
            samples: samples,
            matches: { index, values in
                guard index > 0 else { return false }
                return abs(angleDelta(
                    attitudes[index].roll,
                    attitudes[index - 1].roll
                )) > 15
                    && values[index].speed < 100
                    && values[index].verticalSpeed < -1_500
            },
            to: &figures
        )
        return figures.sorted { $0.startIndex < $1.startIndex }
    }

    nonisolated private static func appendRuns(
        kind: FigureKind,
        minimumLength: Int,
        samples: [FlightSample],
        matches: (Int, [FlightSample]) -> Bool,
        to figures: inout [FlightFigure]
    ) {
        var start: Int?
        for index in samples.indices {
            if matches(index, samples) {
                if start == nil { start = index }
            } else if let runStart = start {
                if index - runStart > minimumLength {
                    figures.append(
                        FlightFigure(
                            kind: kind,
                            startIndex: runStart,
                            endIndex: index,
                            startTime: samples[runStart].elapsed,
                            endTime: samples[index].elapsed
                        )
                    )
                }
                start = nil
            }
        }
        if let runStart = start, samples.count - runStart > minimumLength {
            figures.append(
                FlightFigure(
                    kind: kind,
                    startIndex: runStart,
                    endIndex: samples.count - 1,
                    startTime: samples[runStart].elapsed,
                    endTime: samples[samples.count - 1].elapsed
                )
            )
        }
    }

    nonisolated private static func appendRuns(
        kind: FigureKind,
        minimumLength: Int,
        samples: [FlightSample],
        matches: (FlightSample) -> Bool,
        to figures: inout [FlightFigure]
    ) {
        appendRuns(
            kind: kind,
            minimumLength: minimumLength,
            samples: samples,
            matches: { index, values in matches(values[index]) },
            to: &figures
        )
    }

    nonisolated private static func angleDelta(_ lhs: Double, _ rhs: Double) -> Double {
        var delta = lhs - rhs
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }
}

enum CSVParser {
    nonisolated static func rows(in text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var insideQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if character == "\"" {
                let next = text.index(after: index)
                if insideQuotes, next < text.endIndex, text[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == ",", !insideQuotes {
                row.append(field)
                field = ""
            } else if character == "\n", !insideQuotes {
                row.append(field.trimmingCharacters(in: .newlines))
                if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
            index = text.index(after: index)
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
