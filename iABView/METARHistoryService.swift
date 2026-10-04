import Foundation

enum METARHistoryError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case serverError(Int)
    case unreadableResponse
    case missingColumns
    case invalidFlightCSV
    case noReports

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Impossible de préparer la requête METAR."
        case .invalidResponse:
            "La réponse du serveur METAR est invalide."
        case .serverError(let statusCode):
            "Le serveur METAR a répondu avec le code HTTP \(statusCode)."
        case .unreadableResponse:
            "La réponse METAR ne peut pas être lue."
        case .missingColumns:
            "La réponse Ogimet ne contient pas les colonnes attendues."
        case .invalidFlightCSV:
            "merged_data.csv ne contient pas les colonnes nécessaires au recalcul de gps_ias."
        case .noReports:
            "Aucun METAR historique n’a été trouvé pour ce vol."
        }
    }
}

enum METARHistoryService {
    private static let station = "LFMT"

    nonisolated static func update(
        bundleURL: URL,
        flightDate: Date
    ) async throws -> [METARReading] {
        let interval = queryInterval(for: flightDate)
        let responseText = try await download(from: interval.lowerBound, to: interval.upperBound)
        let readings = try parse(responseText)

        guard !readings.isEmpty else {
            throw METARHistoryError.noReports
        }

        let csv = makeCSV(from: readings)
        try csv.write(
            to: bundleURL.appendingPathComponent("metar.csv"),
            atomically: true,
            encoding: .utf8
        )
        try updateIndicatedAirspeed(in: bundleURL, using: readings)
        return readings
    }

    private nonisolated static func queryInterval(for flightDate: Date) -> ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        let components = calendar.dateComponents([.year, .month, .day], from: flightDate)
        let start = calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 6
            )
        ) ?? flightDate
        return start...start.addingTimeInterval(12 * 60 * 60)
    }

    private nonisolated static func download(from start: Date, to end: Date) async throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmm"

        var components = URLComponents(string: "https://www.ogimet.com/cgi-bin/getmetar")
        components?.queryItems = [
            URLQueryItem(name: "icao", value: station),
            URLQueryItem(name: "begin", value: formatter.string(from: start)),
            URLQueryItem(name: "end", value: formatter.string(from: end)),
            URLQueryItem(name: "lang", value: "eng"),
            URLQueryItem(name: "header", value: "yes")
        ]
        guard let url = components?.url else {
            throw METARHistoryError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw METARHistoryError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw METARHistoryError.serverError(httpResponse.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw METARHistoryError.unreadableResponse
        }
        return text
    }

    private nonisolated static func parse(_ text: String) throws -> [METARReading] {
        let rows = CSVParser.rows(in: text)
        guard let header = rows.first else {
            throw METARHistoryError.missingColumns
        }

        let columns = Dictionary(
            uniqueKeysWithValues: header.enumerated().map {
                ($1.trimmingCharacters(in: .whitespacesAndNewlines), $0)
            }
        )
        let requiredColumns = ["ANO", "MES", "DIA", "HORA", "MINUTO", "PARTE"]
        guard requiredColumns.allSatisfy({ columns[$0] != nil }) else {
            throw METARHistoryError.missingColumns
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        return rows.dropFirst().compactMap { row in
            func integer(_ column: String) -> Int? {
                guard let index = columns[column], row.indices.contains(index) else { return nil }
                return Int(row[index].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard let year = integer("ANO"),
                  let month = integer("MES"),
                  let day = integer("DIA"),
                  let hour = integer("HORA"),
                  let minute = integer("MINUTO"),
                  let reportIndex = columns["PARTE"],
                  row.indices.contains(reportIndex),
                  let date = calendar.date(
                    from: DateComponents(
                        timeZone: calendar.timeZone,
                        year: year,
                        month: month,
                        day: day,
                        hour: hour,
                        minute: minute
                    )
                  ) else {
                return nil
            }

            let report = row[reportIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            return report.isEmpty ? nil : METARReading(date: date, report: report)
        }
        .sorted { $0.date < $1.date }
    }

    private nonisolated static func updateIndicatedAirspeed(
        in bundleURL: URL,
        using readings: [METARReading]
    ) throws {
        let mergedURL = bundleURL.appendingPathComponent("merged_data.csv")
        let text = try String(contentsOf: mergedURL, encoding: .utf8)
        var rows = CSVParser.rows(in: text)
        guard !rows.isEmpty else { throw METARHistoryError.invalidFlightCSV }

        var header = rows[0]
        let columns = Dictionary(
            uniqueKeysWithValues: header.enumerated().map {
                ($1.trimmingCharacters(in: .whitespacesAndNewlines), $0)
            }
        )
        guard let timestampIndex = columns["timestamp"],
              let speedIndex = columns["gps_speed"],
              let headingIndex = columns["gps_heading"] else {
            throw METARHistoryError.invalidFlightCSV
        }

        let iasIndex: Int
        if let existingIndex = columns["gps_ias"] {
            iasIndex = existingIndex
        } else {
            iasIndex = header.count
            header.append("gps_ias")
            rows[0] = header
        }

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

        func date(from value: String) -> Date? {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            for formatter in timestampFormatters {
                if let date = formatter.date(from: normalized) { return date }
            }
            return isoFormatter.date(from: normalized)
                ?? isoFormatterWithoutFractions.date(from: normalized)
        }

        for index in rows.indices.dropFirst() {
            var row = rows[index]
            while row.count <= iasIndex {
                row.append("")
            }
            guard row.indices.contains(timestampIndex),
                  row.indices.contains(speedIndex),
                  row.indices.contains(headingIndex),
                  let timestamp = date(from: row[timestampIndex]),
                  let groundSpeed = Double(row[speedIndex]),
                  let heading = Double(row[headingIndex]) else {
                rows[index] = row
                continue
            }

            var indicatedAirspeed = groundSpeed
            if groundSpeed >= 50,
               let reading = nearestReading(to: timestamp, in: readings),
               let wind = METARWind(report: reading.report),
               let windDirection = wind.direction {
                let relativeAngle = (windDirection - heading) * .pi / 180
                let headwind = wind.speed * 1.852 * cos(relativeAngle)
                indicatedAirspeed = groundSpeed + headwind
            }
            row[iasIndex] = String(indicatedAirspeed)
            rows[index] = row
        }

        let updatedCSV = rows.map { row in
            row.map(escapedCSVField).joined(separator: ",")
        }.joined(separator: "\n") + "\n"
        try updatedCSV.write(to: mergedURL, atomically: true, encoding: .utf8)
    }

    private nonisolated static func nearestReading(
        to date: Date,
        in readings: [METARReading]
    ) -> METARReading? {
        guard !readings.isEmpty else { return nil }

        var lower = 0
        var upper = readings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if readings[middle].date < date {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        guard lower > 0 else { return readings[0] }
        guard lower < readings.count else { return readings[readings.count - 1] }
        let before = readings[lower - 1]
        let after = readings[lower]
        return date.timeIntervalSince(before.date) <= after.date.timeIntervalSince(date)
            ? before
            : after
    }

    private nonisolated static func makeCSV(from readings: [METARReading]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let rows = readings.map {
            "\(formatter.string(from: $0.date)),\(escapedCSVField($0.report))"
        }
        return (["time,metar"] + rows).joined(separator: "\n") + "\n"
    }

    private nonisolated static func escapedCSVField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
