#if os(macOS)
import AppKit
import AVFoundation
import Foundation
import Observation

/// Mode de découpe des vidéos : copie des flux (rapide, sans perte) ou ré-encodage (image par image).
enum ABVEditorMode: String, CaseIterable, Identifiable, Sendable {
    case copy
    case reencode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: "Copie (sans ré-encodage)"
        case .reencode: "Ré-encodage"
        }
    }

    var detail: String {
        switch self {
        case .copy: "Très rapide et sans perte ; la coupe de début est calée sur l’image clé précédente."
        case .reencode: "Plus lent ; coupe exacte à l’image près, fichiers à débit contrôlé."
        }
    }
}

/// Plage conservée de la timeline (en secondes de vidéo).
struct ABVEditorSegment: Equatable, Identifiable, Sendable {
    var id = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var length: TimeInterval { end - start }
}

struct ABVEditorBookmark: Equatable, Identifiable {
    let id = UUID()
    let name: String
    let time: TimeInterval
}

struct ABVEditorSizeReport: Sendable, Equatable {
    let originalBytes: Int64
    let newBytes: Int64

    var savedBytes: Int64 { originalBytes - newBytes }
    var savedFraction: Double { originalBytes > 0 ? Double(savedBytes) / Double(originalBytes) : 0 }
}

@MainActor
@Observable
final class ABVEditorModel {
    enum State: Equatable {
        case idle
        case running
        case succeeded
        case failed(String)
    }

    private(set) var sourceURL: URL?
    private(set) var duration: TimeInterval = 0
    private(set) var frameRate = 30.0
    private(set) var thumbnails: [CGImage] = []
    private(set) var sourceBytes: Int64 = 0
    private(set) var videoBytes: Int64 = 0
    private(set) var bookmarks: [ABVEditorBookmark] = []

    /// Plages conservées, triées et sans chevauchement ; `selectedIndex` est celle dont on règle les bornes.
    private(set) var segments: [ABVEditorSegment] = []
    private(set) var selectedIndex = 0
    private static let minimumLength = 0.5

    var start: TimeInterval { segments.indices.contains(selectedIndex) ? segments[selectedIndex].start : 0 }
    var end: TimeInterval { segments.indices.contains(selectedIndex) ? segments[selectedIndex].end : 0 }
    var playhead: TimeInterval = 0
    var mode = ABVEditorMode.copy

    private(set) var state = State.idle
    private(set) var progress = 0.0
    private(set) var currentStep: String?
    private(set) var report: ABVEditorSizeReport?
    private(set) var outputURL: URL?
    private(set) var isPlaying = false

    let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    private var token: ABVCreatorCancellationToken?
    private(set) var bitrates: [String: Int] = [:]

    var hasSource: Bool { sourceURL != nil && duration > 0 }
    var croppedDuration: TimeInterval { segments.reduce(0) { $0 + $1.length } }
    var canExport: Bool { hasSource && croppedDuration >= 0.5 && state != .running }

    /// Nom proposé pour le nouveau fichier : nom du bundle édité + « _edit ».
    var suggestedName: String {
        guard let sourceURL else { return "Vol_edit.abv" }
        return sourceURL.deletingPathExtension().lastPathComponent + "_edit.abv"
    }

    /// Taille estimée du résultat. Copie : les vidéos au prorata de la durée. Ré-encodage : débit
    /// demandé à l'encodeur (celui de chaque source) × durée, plus l'audio AAC de 192 kb/s.
    var estimatedBytes: Int64 {
        guard duration > 0 else { return sourceBytes }
        let others = sourceBytes - videoBytes
        switch mode {
        case .copy:
            return others + Int64(Double(videoBytes) * min(1, croppedDuration / duration))
        case .reencode:
            guard !bitrates.isEmpty else {
                return others + Int64(Double(videoBytes) * min(1, croppedDuration / duration))
            }
            let perSecond = bitrates.reduce(0.0) { total, entry in
                total + Double(entry.value) / 8 + (entry.key == "video360.mp4" ? 0 : 192_000 / 8)
            }
            return others + Int64(perSecond * croppedDuration)
        }
    }

    init() {
        let model = WeakEditorModel(self)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 20.0, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                guard let value = model.value, seconds.isFinite else { return }
                value.playhead = seconds
                // La lecture reste dans la zone conservée.
                if value.isPlaying, seconds >= value.end {
                    value.pause()
                    value.seek(to: value.end)
                }
            }
        }
    }

    // MARK: - Chargement

    func load(_ url: URL) async {
        guard state != .running else { return }
        let front = url.appendingPathComponent("front.mp4")
        guard FileManager.default.fileExists(atPath: front.path),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("merged_data.csv").path) else {
            state = .failed("« \(url.lastPathComponent) » n’est pas un bundle ABV valide (front.mp4 et merged_data.csv attendus).")
            return
        }
        pause()
        let asset = AVURLAsset(url: front)
        do {
            let length = try await asset.load(.duration).seconds
            guard length.isFinite, length > 0 else { throw ABVCreatorError.invalidData("Durée vidéo illisible.") }
            let rate = (try? await asset.loadTracks(withMediaType: .video).first?.load(.nominalFrameRate)) ?? 30
            sourceURL = url
            duration = length
            frameRate = rate > 1 ? Double(rate) : 30
            segments = [ABVEditorSegment(start: 0, end: length)]
            selectedIndex = 0
            playhead = 0
            report = nil
            outputURL = nil
            state = .idle
            progress = 0
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            bookmarks = FlightBundleLoader.loadBookmarks(from: url.appendingPathComponent("bookmark.csv"))
                .map { ABVEditorBookmark(name: $0.name, time: Double($0.frame) / self.frameRate) }
            let measured = await Task.detached { ABVEditorPipeline.measure(url) }.value
            sourceBytes = measured.total
            videoBytes = measured.video
            bitrates = await Task.detached { await ABVEditorPipeline.bitrates(in: url) }.value
            thumbnails = await Self.makeThumbnails(for: asset, duration: length)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private static func makeThumbnails(for asset: AVURLAsset, duration: TimeInterval, count: Int = 16) async -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var images: [CGImage] = []
        for index in 0..<count {
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image { images.append(image) }
        }
        return images
    }

    // MARK: - Lecture

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            if playhead < start || playhead >= end - 0.05 { seek(to: start) }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let target = min(max(0, time), duration)
        playhead = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        pause()
        seek(to: playhead + Double(frames) / frameRate)
    }

    // MARK: - Bornes

    /// Le début ne peut pas dépasser la fin ni empiéter sur le segment précédent.
    func setStart(_ value: TimeInterval) {
        guard segments.indices.contains(selectedIndex) else { return }
        let lower = selectedIndex > 0 ? segments[selectedIndex - 1].end + 0.1 : 0
        segments[selectedIndex].start = min(max(lower, value), segments[selectedIndex].end - Self.minimumLength)
    }

    func setEnd(_ value: TimeInterval) {
        guard segments.indices.contains(selectedIndex) else { return }
        let upper = selectedIndex + 1 < segments.count ? segments[selectedIndex + 1].start - 0.1 : duration
        segments[selectedIndex].end = max(min(upper, value), segments[selectedIndex].start + Self.minimumLength)
    }

    func markStartAtPlayhead() { setStart(playhead) }
    func markEndAtPlayhead() { setEnd(playhead) }

    func resetBounds() {
        segments = [ABVEditorSegment(start: 0, end: duration)]
        selectedIndex = 0
    }

    /// Sélectionne le segment qui contient cet instant, s'il y en a un.
    func selectSegment(containing time: TimeInterval) {
        if let index = segments.firstIndex(where: { time >= $0.start && time <= $0.end }) {
            selectedIndex = index
        }
    }

    var canAddSegment: Bool { newSegmentRange() != nil }

    /// Place libre pour un nouveau segment : à partir de la tête de lecture si elle est dans un trou,
    /// sinon juste après le segment sélectionné. Jusqu'à 10 s, limité par le segment suivant.
    private func newSegmentRange() -> ClosedRange<TimeInterval>? {
        let candidates = [playhead, end + 0.1]
        for origin in candidates {
            guard !segments.contains(where: { origin >= $0.start - 0.1 && origin <= $0.end + 0.1 }) else { continue }
            let limit = segments.first(where: { $0.start > origin })?.start.advanced(by: -0.1) ?? duration
            let finish = min(origin + 10, limit)
            if finish - origin >= Self.minimumLength { return origin...finish }
        }
        return nil
    }

    func addSegment() {
        guard let range = newSegmentRange() else { return }
        segments.append(ABVEditorSegment(start: range.lowerBound, end: range.upperBound))
        segments.sort { $0.start < $1.start }
        selectedIndex = segments.firstIndex { $0.start == range.lowerBound } ?? 0
    }

    func removeSelectedSegment() {
        guard segments.count > 1 else { return }
        segments.remove(at: selectedIndex)
        selectedIndex = min(selectedIndex, segments.count - 1)
    }

    func jumpToBookmark(forward: Bool) {
        pause()
        let target = forward
            ? bookmarks.first { $0.time > playhead + 0.05 }
            : bookmarks.last { $0.time < playhead - 0.05 }
        if let target { seek(to: target.time) }
    }

    // MARK: - Export

    func export(to destination: URL) {
        guard canExport, let sourceURL else { return }
        state = .running
        progress = 0
        report = nil
        outputURL = nil
        currentStep = "Préparation…"
        pause()
        let ranges = segments.map { (start: $0.start, end: $0.end) }
        let mode = mode
        let fps = frameRate
        let rates = bitrates
        let token = ABVCreatorCancellationToken()
        self.token = token
        ABVCreatorProcessRegistry.register(token)
        let (stream, continuation) = AsyncStream<ABVCreatorProgress>.makeStream()
        Task {
            for await update in stream {
                progress = update.fraction
                if let step = update.step { currentStep = step }
            }
        }
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ABVEditorPipeline.export(
                        source: sourceURL, destination: destination, segments: ranges, mode: mode,
                        frameRate: fps, bitrates: rates, cancellation: token
                    ) { continuation.yield($0) }
                }.value
                continuation.finish()
                ABVCreatorProcessRegistry.unregister(token)
                outputURL = destination
                report = result
                progress = 1
                currentStep = nil
                state = .succeeded
            } catch {
                continuation.finish()
                ABVCreatorProcessRegistry.unregister(token)
                currentStep = nil
                state = .failed(error.localizedDescription)
            }
            self.token = nil
        }
    }

    func cancel() {
        token?.cancel()
    }
}

private final class WeakEditorModel: @unchecked Sendable {
    weak var value: ABVEditorModel?
    init(_ value: ABVEditorModel) { self.value = value }
}

// MARK: - Pipeline

enum ABVEditorPipeline {
    private static let videoNames = ["front.mp4", "back.mp4", "video360.mp4"]

    /// Taille totale du bundle et part occupée par les vidéos.
    nonisolated static func measure(_ bundle: URL) -> (total: Int64, video: Int64) {
        var total: Int64 = 0
        var video: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys) else {
            return (0, 0)
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
            total += size
            if videoNames.contains(url.lastPathComponent), url.deletingLastPathComponent() == bundle { video += size }
        }
        return (total, video)
    }

    /// Débit vidéo de chaque fichier, pour que le ré-encodage garde une taille comparable.
    nonisolated static func bitrates(in bundle: URL) async -> [String: Int] {
        var result: [String: Int] = [:]
        for name in videoNames {
            let url = bundle.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path),
                  let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let rate = try? await track.load(.estimatedDataRate), rate > 0 else { continue }
            result[name] = Int(rate)
        }
        return result
    }

    nonisolated static func export(
        source: URL, destination: URL, segments: [(start: TimeInterval, end: TimeInterval)],
        mode: ABVEditorMode, frameRate: Double, bitrates: [String: Int],
        cancellation: ABVCreatorCancellationToken,
        progress: @escaping @Sendable (ABVCreatorProgress) -> Void
    ) throws -> ABVEditorSizeReport {
        let fileManager = FileManager.default
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else {
            throw ABVCreatorError.invalidData("Le fichier ABV d’origine ne peut pas être écrasé : choisissez un autre nom.")
        }
        let ffmpeg = try ABVCreatorPipelineAccess.ffmpeg()
        // Écriture dans un dossier temporaire voisin, déplacé à la fin : une annulation ne laisse rien d’à moitié écrit.
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial")
        try? fileManager.removeItem(at: partial)
        try fileManager.createDirectory(at: partial, withIntermediateDirectories: true)
        var finished = false
        defer { if !finished { try? fileManager.removeItem(at: partial) } }

        let total = segments.reduce(0) { $0 + ($1.end - $1.start) }
        let videos = videoNames.filter { fileManager.fileExists(atPath: source.appendingPathComponent($0).path) }
        let partsDirectory = partial.appendingPathComponent(".parts")
        for (index, name) in videos.enumerated() {
            try cancellation.checkCancelled()
            progress(ABVCreatorProgress(
                fraction: Double(index) / Double(videos.count + 1), message: nil, ffmpegCPUUsage: nil,
                step: "Vidéo \(index + 1)/\(videos.count) : \(name)"
            ))
            var partURLs: [URL] = []
            var doneLength = 0.0
            for (part, segment) in segments.enumerated() {
                let output: URL
                if segments.count == 1 {
                    output = partial.appendingPathComponent(name)
                } else {
                    try fileManager.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
                    output = partsDirectory.appendingPathComponent("\(index)_\(part).mp4")
                }
                let status = ABVFFmpegStatus()
                let finished = doneLength
                let arguments = ffmpegArguments(
                    input: source.appendingPathComponent(name), output: output,
                    range: segment, mode: mode, hasAudio: name != "video360.mp4", bitrate: bitrates[name]
                )
                try run(ffmpeg, arguments, status: status, cancellation: cancellation) {
                    let done = (finished + min(segment.end - segment.start, status.snapshot.time ?? 0)) / max(total, 0.1)
                    progress(ABVCreatorProgress(
                        fraction: (Double(index) + min(1, done)) / Double(videos.count + 1), message: nil, ffmpegCPUUsage: nil
                    ))
                }
                doneLength += segment.end - segment.start
                partURLs.append(output)
            }
            if segments.count > 1 {
                // Assemblage des morceaux sans ré-encodage.
                let list = partsDirectory.appendingPathComponent("\(index).txt")
                let text = partURLs.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
                try text.write(to: list, atomically: true, encoding: .utf8)
                try run(
                    ffmpeg,
                    ["-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
                     "-c", "copy", partial.appendingPathComponent(name).path],
                    status: ABVFFmpegStatus(), cancellation: cancellation, onTick: {}
                )
            }
        }
        try? fileManager.removeItem(at: partsDirectory)

        progress(ABVCreatorProgress(fraction: Double(videos.count) / Double(videos.count + 1),
                                    message: nil, ffmpegCPUUsage: nil, step: "Données de vol…"))
        try cropTelemetry(from: source, to: partial, segments: segments, frameRate: frameRate)

        // Tout le reste (METAR, calages, etc.) est repris tel quel.
        let handled = Set(videoNames + ["merged_data.csv", "bookmark.csv"])
        for name in (try? fileManager.contentsOfDirectory(atPath: source.path)) ?? [] where !handled.contains(name) {
            try? fileManager.copyItem(at: source.appendingPathComponent(name), to: partial.appendingPathComponent(name))
        }

        try cancellation.checkCancelled()
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.moveItem(at: partial, to: destination)
        finished = true
        ABVEditorPipeline.markAsPackage(destination)
        return ABVEditorSizeReport(originalBytes: measure(source).total, newBytes: measure(destination).total)
    }

    nonisolated static func ffmpegArguments(
        input: URL, output: URL, range: (start: TimeInterval, end: TimeInterval),
        mode: ABVEditorMode, hasAudio: Bool, bitrate: Int?
    ) -> [String] {
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-stats", "-y",
            "-ss", String(format: "%.3f", range.start), "-i", input.path,
            "-t", String(format: "%.3f", range.end - range.start),
            "-map", "0:v:0"
        ]
        if hasAudio { arguments += ["-map", "0:a?"] }
        switch mode {
        case .copy:
            arguments += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        case .reencode:
            let rate = max(1_000_000, bitrate ?? 8_000_000)
            arguments += [
                "-c:v", "h264_videotoolbox", "-b:v", String(rate), "-maxrate", String(rate),
                "-bufsize", String(rate * 3), "-profile:v", "high", "-g", "60", "-allow_sw", "1",
                "-pix_fmt", "yuv420p"
            ]
            arguments += hasAudio ? ["-c:a", "aac", "-b:a", "192k"] : ["-an"]
        }
        arguments.append(output.path)
        return arguments
    }

    nonisolated static func run(
        _ executable: URL, _ arguments: [String], status: ABVFFmpegStatus,
        cancellation: ABVCreatorCancellationToken, onTick: @escaping @Sendable () -> Void
    ) throws {
        try cancellation.checkCancelled()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let tail = OutputTail()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            status.ingest(text)
            tail.append(text)
            onTick()
        }
        ABVDebugConsole.emit("$ " + ([executable.path] + arguments).map(ABVDebugConsole.quoted).joined(separator: " "))
        try process.run()
        cancellation.track(process)
        defer { cancellation.untrack() }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if cancellation.isCancelled { throw ABVCreatorError.cancelled }
        guard process.terminationStatus == 0 else {
            throw ABVCreatorError.commandFailed(executable.lastPathComponent, tail.text)
        }
    }

    /// Ne garde que les lignes de `merged_data.csv` et les favoris situés dans les segments, recalés sur 0.
    /// Avec plusieurs segments, `timestamp` et `timestamp_ms` sont réécrits pour que la timeline reste continue.
    nonisolated static func cropTelemetry(
        from source: URL, to output: URL, segments: [(start: TimeInterval, end: TimeInterval)], frameRate: Double
    ) throws {
        let text = try String(contentsOf: source.appendingPathComponent("merged_data.csv"), encoding: .utf8)
        let rewrites = segments.count > 1
        // Durée cumulée des segments qui précèdent chacun d'eux.
        var offsets: [TimeInterval] = []
        var running = 0.0
        for segment in segments {
            offsets.append(running)
            running += segment.end - segment.start
        }
        var lines: [String] = []
        var timestampColumn: Int?
        var millisecondsColumn: Int?
        var origin: Date?
        var firstKeptDate: Date?
        var firstKeptMilliseconds: Double?
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        text.enumerateLines { line, _ in
            guard let column = timestampColumn else {
                lines.append(line)
                let headers = CSVParser.fields(in: line)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff} ")) }
                timestampColumn = headers.firstIndex(of: "timestamp")
                millisecondsColumn = headers.firstIndex(of: "timestamp_ms")
                return
            }
            var fields = CSVParser.fields(in: line)
            guard fields.indices.contains(column),
                  let date = fractional.date(from: fields[column]) ?? plain.date(from: fields[column]) else { return }
            if origin == nil { origin = date }
            let elapsed = date.timeIntervalSince(origin ?? date)
            guard let index = segments.firstIndex(where: { elapsed >= $0.start && elapsed <= $0.end }) else { return }
            if rewrites {
                let newOffset = offsets[index] + elapsed - segments[index].start
                if firstKeptDate == nil { firstKeptDate = date }
                fields[column] = fractional.string(from: (firstKeptDate ?? date).addingTimeInterval(newOffset))
                if let msColumn = millisecondsColumn, fields.indices.contains(msColumn),
                   let milliseconds = Double(fields[msColumn]) {
                    if firstKeptMilliseconds == nil { firstKeptMilliseconds = milliseconds }
                    fields[msColumn] = String(Int(((firstKeptMilliseconds ?? milliseconds) + newOffset * 1_000).rounded()))
                }
                lines.append(fields.joined(separator: ","))
            } else {
                lines.append(line)
            }
        }
        guard timestampColumn != nil, lines.count > 1 else {
            throw ABVCreatorError.invalidData("Aucune donnée de vol dans la plage sélectionnée.")
        }
        try (lines.joined(separator: "\n") + "\n")
            .write(to: output.appendingPathComponent("merged_data.csv"), atomically: true, encoding: .utf8)

        let bookmarkURL = source.appendingPathComponent("bookmark.csv")
        guard let bookmarkText = try? String(contentsOf: bookmarkURL, encoding: .utf8) else { return }
        var kept = ["time,name,frame"]
        for row in CSVParser.rows(in: bookmarkText).dropFirst() where row.count >= 3 {
            guard let frame = Int(row[2]) else { continue }
            let time = Double(frame) / frameRate
            guard let index = segments.firstIndex(where: { time >= $0.start && time <= $0.end }) else { continue }
            let newTime = offsets[index] + time - segments[index].start
            let newFrame = max(0, frame - Int((segments[index].start * frameRate).rounded())
                               + Int((offsets[index] * frameRate).rounded()))
            let name = row[1].contains(",") || row[1].contains("\"")
                ? "\"" + row[1].replacingOccurrences(of: "\"", with: "\"\"") + "\"" : row[1]
            kept.append("\(newTime.clockString),\(name),\(newFrame)")
        }
        try (kept.joined(separator: "\n") + "\n")
            .write(to: output.appendingPathComponent("bookmark.csv"), atomically: true, encoding: .utf8)
    }

    nonisolated static func markAsPackage(_ url: URL) {
        var finderInfo = [UInt8](repeating: 0, count: 32)
        finderInfo[8] = 0x20
        _ = url.path.withCString { path in
            finderInfo.withUnsafeBytes { setxattr(path, "com.apple.FinderInfo", $0.baseAddress, 32, 0, 0) }
        }
    }
}

/// Dernières lignes de sortie d’un processus, pour les messages d’erreur.
private final class OutputTail: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var buffer = ""

    nonisolated init() {}

    nonisolated func append(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        buffer = String((buffer + chunk).suffix(2_000))
    }

    nonisolated var text: String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

/// Accès à la recherche de ffmpeg, partagée avec le créateur d’ABV.
enum ABVCreatorPipelineAccess {
    nonisolated static func ffmpeg() throws -> URL {
        for path in ABVTool.ffmpeg.candidates where !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw ABVCreatorError.missingTool("FFmpeg")
    }
}
#endif
