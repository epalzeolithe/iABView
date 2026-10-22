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
        return (windSpeed / 1.852) * cos(relativeAngle)
    }

    var crosswind: Double {
        let relativeAngle = (heading - windDirection) * .pi / 180
        return (windSpeed / 1.852) * sin(relativeAngle)
    }

    var energy: Double {
        let convertedSpeed = speed / 12.96
        return 0.5 * convertedSpeed * convertedSpeed + 9.81 * altitude * 0.3048
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
        let orientation = correctedOrientation(
            mountingPitch: mountingPitch,
            isInverted: isInverted
        )
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

    nonisolated func wingtipAttitude(
        mountingPitch: Double,
        isInverted: Bool
    ) -> Attitude {
        let orientation = correctedOrientation(
            mountingPitch: mountingPitch,
            isInverted: isInverted
        )

        // Equivalent to R_view_wing @ R_final in the Python implementation.
        let forward = orientation.act(SIMD3<Double>(1, 0, 0))
        let up = orientation.act(SIMD3<Double>(0, 0, 1))
        let pitch = -asin(max(-1, min(1, forward.z))) * 180 / .pi
        let right = simd_cross(forward, up)
        let roll = atan2(right.z, up.z) * 180 / .pi
        return Attitude(roll: roll, pitch: pitch)
    }

    nonisolated private func correctedOrientation(
        mountingPitch: Double,
        isInverted: Bool
    ) -> simd_quatd {
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
        return sensor * inversion * axisCorrection * mountingCorrection
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

struct METARWind: Sendable {
    let direction: Double?
    let speed: Double
    let gust: Double?

    nonisolated init?(report: String) {
        let pattern = #"^(\d{3}|VRB)(\d{2,3})(?:G(\d{2,3}))?(KT|MPS)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }

        let tokens = report.uppercased().split(whereSeparator: { $0.isWhitespace })
        guard let token = tokens.first(where: {
            let text = String($0)
            let range = NSRange(text.startIndex..., in: text)
            return expression.firstMatch(in: text, range: range)?.range == range
        }) else {
            return nil
        }

        let text = String(token)
        let fullRange = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: fullRange),
              let speedRange = Range(match.range(at: 2), in: text),
              let parsedSpeed = Double(text[speedRange]),
              let unitRange = Range(match.range(at: 4), in: text) else {
            return nil
        }

        let multiplier = text[unitRange] == "MPS" ? 1.943_844 : 1
        if let directionRange = Range(match.range(at: 1), in: text) {
            let directionText = text[directionRange]
            direction = directionText == "VRB" ? nil : Double(directionText)
        } else {
            direction = nil
        }
        speed = parsedSpeed * multiplier

        if let gustRange = Range(match.range(at: 3), in: text),
           let parsedGust = Double(text[gustRange]) {
            gust = parsedGust * multiplier
        } else {
            gust = nil
        }
    }

    nonisolated func headwind(for heading: Double) -> Double? {
        guard let direction else { return nil }
        let relativeAngle = (heading - direction) * .pi / 180
        return speed * cos(relativeAngle)
    }

    nonisolated func crosswind(for heading: Double) -> Double? {
        guard let direction else { return nil }
        let relativeAngle = (heading - direction) * .pi / 180
        return speed * sin(relativeAngle)
    }
}

struct METARReading: Sendable {
    let date: Date
    let report: String
}

struct FlightBundle: Sendable {
    let url: URL
    let samples: [FlightSample]
    let bookmarks: [FlightBookmark]
    let metar: [METARReading]
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
        let timestampFormatters = [
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterWithoutFractions = ISO8601DateFormatter()
        isoFormatterWithoutFractions.formatOptions = [.withInternetDateTime]
        func timestamp(from text: String) -> Date? {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for formatter in timestampFormatters {
                if let date = formatter.date(from: normalized) { return date }
            }
            return isoFormatter.date(from: normalized)
                ?? isoFormatterWithoutFractions.date(from: normalized)
        }

        var columns: [String: Int] = [:]
        var samples: [FlightSample] = []
        samples.reserveCapacity(max(1_000, csv.utf8.count / 240))
        var firstTimestamp: Date?
        var segmentStartMilliseconds: Double?
        var segmentStartElapsed: TimeInterval = 0
        var previousMilliseconds: Double?
        var previousElapsed = -Double.infinity
        var isChronological = true
        var offset = 0

        csv.enumerateLines { line, _ in
            let row = CSVParser.fields(in: line)
            guard !row.isEmpty else { return }
            if columns.isEmpty {
                let headers = row.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
                }
                columns = Dictionary(
                    uniqueKeysWithValues: headers.enumerated().map { ($1, $0) }
                )
                return
            }

            func value(_ name: String) -> String {
                guard let index = columns[name], row.indices.contains(index) else { return "" }
                return row[index]
            }
            func number(_ name: String) -> Double {
                Double(value(name)) ?? 0
            }

            if firstTimestamp == nil {
                firstTimestamp = timestamp(from: value("timestamp"))
                segmentStartMilliseconds = Double(value("timestamp_ms"))
            }
            guard let origin = firstTimestamp else { return }

            let elapsed: TimeInterval
            if let milliseconds = Double(value("timestamp_ms")),
               let startMilliseconds = segmentStartMilliseconds {
                if let previousMilliseconds, milliseconds < previousMilliseconds {
                    guard let absoluteTimestamp = timestamp(from: value("timestamp")) else { return }
                    segmentStartElapsed = max(0, absoluteTimestamp.timeIntervalSince(origin))
                    segmentStartMilliseconds = milliseconds
                    elapsed = segmentStartElapsed
                } else {
                    elapsed = max(
                        0,
                        segmentStartElapsed + (milliseconds - startMilliseconds) / 1_000
                    )
                }
                previousMilliseconds = milliseconds
            } else if let parsedTimestamp = timestamp(from: value("timestamp")) {
                elapsed = max(0, parsedTimestamp.timeIntervalSince(origin))
            } else {
                return
            }
            let sampleTimestamp = origin.addingTimeInterval(elapsed)
            if elapsed < previousElapsed { isChronological = false }
            previousElapsed = elapsed

            samples.append(FlightSample(
                id: Int(row.first ?? "") ?? offset,
                timestamp: sampleTimestamp,
                elapsed: elapsed,
                latitude: number("gps_lat"),
                longitude: number("gps_lon"),
                altitude: number("gps_alt"),
                speed: number("gps_speed"),
                heading: number("gps_heading"),
                verticalSpeed: number("gps_fpm"),
                indicatedAirspeed: number("gps_ias"),
                windSpeed: number("era5_wind_speed"),
                windDirection: number("era5_wind_direction"),
                accelerationX: number("x4_acc_x"),
                accelerationY: number("x4_acc_y"),
                accelerationZ: number("x4_acc_z"),
                quaternionW: number("x4_quat_w"),
                quaternionX: number("x4_quat_x"),
                quaternionY: number("x4_quat_y"),
                quaternionZ: number("x4_quat_z")
            ))
            offset += 1
        }

        guard !samples.isEmpty else { throw FlightLoadError.emptyData }
        if !isChronological {
            samples.sort { $0.timestamp < $1.timestamp }
        }
        return FlightBundle(
            url: url,
            samples: samples,
            bookmarks: loadBookmarks(from: url.appendingPathComponent("bookmark.csv")),
            metar: loadMETAR(from: url.appendingPathComponent("metar.csv"))
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
        let formatters = [
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss"
        ].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            return formatter
        }
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterWithoutFractions = ISO8601DateFormatter()
        isoFormatterWithoutFractions.formatOptions = [.withInternetDateTime]
        func date(from text: String) -> Date? {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            for formatter in formatters {
                if let value = formatter.date(from: normalized) { return value }
            }
            return isoFormatter.date(from: normalized)
                ?? isoFormatterWithoutFractions.date(from: normalized)
        }

        return CSVParser.rows(in: text).dropFirst().compactMap { row in
            guard row.count >= 2, let date = date(from: row[0]) else { return nil }
            return METARReading(date: date, report: row[1])
        }.sorted { $0.date < $1.date }
    }
}

enum CSVParser {
    nonisolated static func fields(in line: String) -> [String] {
        guard line.contains("\"") else {
            return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        }

        var fields: [String] = []
        var field = ""
        var insideQuotes = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if insideQuotes, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = next
                } else {
                    insideQuotes.toggle()
                }
            } else if character == ",", !insideQuotes {
                fields.append(field)
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
            index = line.index(after: index)
        }
        fields.append(field)
        return fields
    }

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
