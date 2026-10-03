#if os(macOS)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import Charts
import MapKit
import SwiftUI

struct VideoPane: View {
    let title: LocalizedStringKey
    let player: AVPlayer
    let timestamp: Date?
    let elapsedTime: TimeInterval
    let previousBookmark: String?
    let upcomingBookmark: String?
    var flightSample: FlightSample?
    var showsFlightData = false
    var timestampAlignment: Alignment = .topTrailing
    var mountingPitch = 15.0
    var isCameraInverted = false

    var body: some View {
        ZStack {
            PlayerSurface(player: player)
                .background(.black)

            VideoInformationOverlay(
                timestamp: timestamp,
                elapsedTime: elapsedTime,
                previousBookmark: previousBookmark,
                upcomingBookmark: upcomingBookmark,
                showsPlaybackStatus: showsFlightData,
                timestampAlignment: timestampAlignment
            )

            if showsFlightData, let flightSample {
                FlightVideoDataOverlay(
                    sample: flightSample,
                    mountingPitch: mountingPitch,
                    isCameraInverted: isCameraInverted
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityLabel(title)
    }
}

#if os(macOS)
private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }
}
#else
private struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    private func configureLayer() {
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = UIColor.black.cgColor
    }
}
#endif

#if os(macOS)
private final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    private func configureLayer() {
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }
}
#endif

struct FlightVideoDataOverlay: View {
    let sample: FlightSample
    let mountingPitch: Double
    let isCameraInverted: Bool

    private var attitude: Attitude {
        sample.attitude(mountingPitch: mountingPitch, isInverted: isCameraInverted)
    }

    var body: some View {
        ZStack {
            VStack(spacing: 8) {
                Spacer()

                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        metric("IAS", value: sample.indicatedAirspeed, unit: "km/h")
                        metric("GS", value: sample.speed, unit: "km/h")
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 4) {
                        ZStack {
                            metric("Cap", value: sample.heading, unit: "°")

                            metric("△", value: aerobaticAxisDeviation, unit: "°")
                                .accessibilityLabel("Écart d’axe")
                                .offset(x: 72)
                        }
                        .frame(width: 270)

                        AnalogInstrumentsView(
                            speed: sample.indicatedAirspeed,
                            altitude: sample.altitude,
                            verticalSpeed: sample.verticalSpeed
                        )
                        .frame(width: 270, height: 86)
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 2)
                        .accessibilityLabel("Instruments de vol")
                    }

                    VStack(alignment: .trailing, spacing: 4) {
                        unlabeledMetric("Altitude", value: sample.altitude, unit: "ft")
                        unlabeledMetric("Vario", value: sample.verticalSpeed, unit: "ft/min")
                    }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            HStack {
                Spacer()
                VStack(spacing: 4) {
                    metric("Assiette", value: attitude.pitch, unit: "°")
                    metric("Roulis", value: attitude.roll, unit: "°")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 42)
        .padding(.bottom, 8)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Données de vol incrustées")
    }

    private var aerobaticAxisDeviation: Double {
        min(angularDifference(sample.heading, 50), angularDifference(sample.heading, 230))
    }

    private func angularDifference(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    private func metric(_ label: LocalizedStringKey, value: Double, unit: String) -> some View {
        let formattedValue = value.formatted(.number.precision(.fractionLength(0)))

        return VStack(spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(verbatim: "\(formattedValue) \(unit)")
                .font(.caption.monospacedDigit().bold())
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
    }

    private func unlabeledMetric(
        _ accessibilityLabel: LocalizedStringKey,
        value: Double,
        unit: String
    ) -> some View {
        let formattedValue = value.formatted(.number.precision(.fractionLength(0)))

        return Text(verbatim: "\(formattedValue) \(unit)")
            .font(.caption.monospacedDigit().bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(.white)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityValue(Text(verbatim: "\(formattedValue) \(unit)"))
    }
}

private struct VideoAttitudeReticle: View {
    let attitude: Attitude

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let pitchOffset = CGFloat(max(-45, min(45, attitude.pitch))) * 2

            ZStack {
                ForEach([-20, -10, 0, 10, 20], id: \.self) { pitchMark in
                    Path { path in
                        let halfWidth: CGFloat = pitchMark == 0 ? 72 : 38
                        let y = center.y + pitchOffset + CGFloat(pitchMark) * 2
                        path.move(to: CGPoint(x: center.x - halfWidth, y: y))
                        path.addLine(to: CGPoint(x: center.x + halfWidth, y: y))
                    }
                    .stroke(
                        pitchMark == 0 ? Color.cyan : Color.white,
                        style: StrokeStyle(lineWidth: pitchMark == 0 ? 2 : 1, dash: [6, 4])
                    )
                }
                .rotationEffect(.degrees(-attitude.roll))

                Path { path in
                    path.move(to: CGPoint(x: center.x - 42, y: center.y))
                    path.addLine(to: CGPoint(x: center.x - 10, y: center.y))
                    path.addLine(to: CGPoint(x: center.x, y: center.y + 8))
                    path.addLine(to: CGPoint(x: center.x + 10, y: center.y))
                    path.addLine(to: CGPoint(x: center.x + 42, y: center.y))
                }
                .stroke(.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            .opacity(0.85)
        }
        .accessibilityHidden(true)
    }
}

struct VideoInformationOverlay: View {
    let timestamp: Date?
    let elapsedTime: TimeInterval
    let previousBookmark: String?
    let upcomingBookmark: String?
    let showsPlaybackStatus: Bool
    let timestampAlignment: Alignment

    var body: some View {
        ZStack {
            if showsPlaybackStatus {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(elapsedTime.clockString)
                            .font(.body.monospacedDigit().bold())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(.regularMaterial, in: Rectangle())

                        if let previousBookmark {
                            Label(previousBookmark, systemImage: "bookmark.fill")
                                .lineLimit(1)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.65), in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }

                    if let upcomingBookmark {
                        Text(upcomingBookmark)
                            .font(.title3.monospaced().bold())
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.regularMaterial, in: Rectangle())
                            .transition(.scale.combined(with: .opacity))
                    }

                    Spacer()
                }
            }

            if let timestamp {
                Text(
                    timestamp,
                    format: .dateTime
                        .day()
                        .month(.wide)
                        .year()
                        .hour()
                        .minute()
                        .second()
                )
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Rectangle())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: timestampAlignment)
            }

        }
        .padding(8)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: upcomingBookmark)
    }
}

struct FlightMapView: View {
    let coordinates: [CLLocationCoordinate2D]
    let sample: FlightSample?
    let metar: String
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        ZStack {
            Map(position: $position) {
                if coordinates.count > 1 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.blue.opacity(0.65), lineWidth: 3)
                    if flownCoordinates.count > 1 {
                        MapPolyline(coordinates: flownCoordinates)
                            .stroke(.purple, lineWidth: 4)
                    }
                }

                if let sample {
                    Annotation("", coordinate: sample.coordinate) {
                        Image(systemName: "airplane")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(sample.heading - 90))
                            .padding(7)
                            .background(.blue, in: Circle())
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls {
                #if os(macOS)
                MapZoomStepper()
                #endif
                MapCompass()
            }

            VStack {
                HStack(alignment: .top) {
                    Button {
                        recenterOnAircraft()
                    } label: {
                        Label("Recentrer sur l’avion", systemImage: "scope")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .help("Recentrer sur l’avion")

                    Spacer()

                    if let sample {
                        WindOverlayView(sample: sample)
                    }
                }

                Spacer()

                if !metar.isEmpty {
                    Text(metar)
                        .font(.caption2.monospaced())
                        .lineLimit(4)
                        .padding(7)
                        .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.black)
                        .frame(maxWidth: 300, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { frameEntireRoute() }
        .onChange(of: coordinates.count) { _, _ in frameEntireRoute() }
    }

    private var flownCoordinates: [CLLocationCoordinate2D] {
        guard let sample, !coordinates.isEmpty else { return [] }
        let nearestIndex = coordinates.indices.min { lhs, rhs in
            coordinateDistanceSquared(coordinates[lhs], sample.coordinate)
                < coordinateDistanceSquared(coordinates[rhs], sample.coordinate)
        } ?? 0
        return Array(coordinates.prefix(through: nearestIndex))
    }

    private func frameEntireRoute() {
        guard let region = routeRegion else { return }
        position = .region(region)
    }

    private func recenterOnAircraft() {
        guard let sample else { return }
        position = .region(
            MKCoordinateRegion(
                center: sample.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08)
            )
        )
    }

    private var routeRegion: MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minimumLatitude = first.latitude
        var maximumLatitude = first.latitude
        var minimumLongitude = first.longitude
        var maximumLongitude = first.longitude
        for coordinate in coordinates.dropFirst() {
            minimumLatitude = min(minimumLatitude, coordinate.latitude)
            maximumLatitude = max(maximumLatitude, coordinate.latitude)
            minimumLongitude = min(minimumLongitude, coordinate.longitude)
            maximumLongitude = max(maximumLongitude, coordinate.longitude)
        }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: (minimumLatitude + maximumLatitude) / 2,
                longitude: (minimumLongitude + maximumLongitude) / 2
            ),
            span: MKCoordinateSpan(
                latitudeDelta: max(0.02, (maximumLatitude - minimumLatitude) * 1.25),
                longitudeDelta: max(0.02, (maximumLongitude - minimumLongitude) * 1.25)
            )
        )
    }

    private func coordinateDistanceSquared(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Double {
        let latitude = lhs.latitude - rhs.latitude
        let longitude = lhs.longitude - rhs.longitude
        return latitude * latitude + longitude * longitude
    }
}

struct WindOverlayView: View {
    let sample: FlightSample

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "location.north.fill")
                    .rotationEffect(.degrees(sample.windDirection))
                    .foregroundStyle(.cyan)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(
                        "\(sample.windSpeed / 1.852, format: .number.precision(.fractionLength(0))) kt"
                    )
                    Text(
                        "\(sample.windDirection, format: .number.precision(.fractionLength(0)))°"
                    )
                }
                .monospacedDigit()
            }
            .font(.headline)

            Text(
                "Face \(sample.headwind, format: .number.precision(.fractionLength(0))) kt"
            )
            Text(
                "Travers \(sample.crosswind, format: .number.precision(.fractionLength(0))) kt"
            )

        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(9)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Informations de vent")
    }
}

enum ArtificialHorizonMarker {
    case wings
    case triangle
}

struct ArtificialHorizonView: View {
    let pitch: Double
    let roll: Double
    var marker: ArtificialHorizonMarker = .wings

    var body: some View {
        GeometryReader { proxy in
            let fillSize = max(proxy.size.width, proxy.size.height) * 4

            ZStack {
                VStack(spacing: 0) {
                    Rectangle().fill(.blue.gradient)
                    Rectangle().fill(.brown.gradient)
                }

                Rectangle()
                    .fill(.white.opacity(0.9))
                    .frame(height: 2)

                ArtificialHorizonPitchLadder()
            }
            .frame(width: fillSize, height: fillSize)
            .rotationEffect(.degrees(-roll))
            .offset(y: pitch * 2)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .overlay {
                Path { path in
                    let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    switch marker {
                    case .wings:
                        path.move(to: CGPoint(x: center.x - 45, y: center.y))
                        path.addLine(to: CGPoint(x: center.x - 10, y: center.y))
                        path.addLine(to: CGPoint(x: center.x, y: center.y + 8))
                        path.addLine(to: CGPoint(x: center.x + 10, y: center.y))
                        path.addLine(to: CGPoint(x: center.x + 45, y: center.y))
                    case .triangle:
                        let size: CGFloat = 27
                        path.move(to: CGPoint(x: center.x, y: center.y - size))
                        path.addLine(to: CGPoint(x: center.x - size, y: center.y))
                        path.addLine(to: CGPoint(x: center.x + size, y: center.y))
                        path.closeSubpath()
                    }
                }
                .stroke(
                    .yellow,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityLabel("Horizon artificiel")
        .accessibilityValue("Tangage \(pitch, format: .number.precision(.fractionLength(0))) degrés, roulis \(roll, format: .number.precision(.fractionLength(0))) degrés")
    }
}

private struct ArtificialHorizonPitchLadder: View {
    private static let marks = [-90, -60, -30, -20, -10, 10, 20, 30, 60, 90]
    private let pointsPerDegree: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let centerX = proxy.size.width / 2
            let centerY = proxy.size.height / 2

            ForEach(Self.marks, id: \.self) { degree in
                let y = centerY - CGFloat(degree) * pointsPerDegree
                let halfWidth = barHalfWidth(for: abs(degree))

                Path { path in
                    path.move(to: CGPoint(x: centerX - halfWidth, y: y))
                    path.addLine(to: CGPoint(x: centerX - 8, y: y))
                    path.move(to: CGPoint(x: centerX + 8, y: y))
                    path.addLine(to: CGPoint(x: centerX + halfWidth, y: y))

                    path.move(to: CGPoint(x: centerX - halfWidth, y: y))
                    path.addLine(to: CGPoint(x: centerX - halfWidth, y: y + 5))
                    path.move(to: CGPoint(x: centerX + halfWidth, y: y))
                    path.addLine(to: CGPoint(x: centerX + halfWidth, y: y + 5))
                }
                .stroke(
                    .white.opacity(0.58),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round)
                )

                Text(verbatim: "\(degree)°")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .position(x: centerX - halfWidth - 22, y: y)

                Text(verbatim: "\(degree)°")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .position(x: centerX + halfWidth + 22, y: y)
            }
        }
        .accessibilityHidden(true)
    }

    private func barHalfWidth(for degree: Int) -> CGFloat {
        switch degree {
        case 10:
            return 42
        case 20, 30:
            return 34
        default:
            return 28
        }
    }
}

struct InstrumentTile: View {
    let title: LocalizedStringKey
    let value: Double
    let unit: LocalizedStringKey
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 72)
        .padding(8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TelemetryPanel: View {
    let sample: FlightSample?
    let signedLoadFactor: Double
    let mountingPitch: Double
    let isCameraInverted: Bool

    private var attitude: Attitude {
        sample?.attitude(mountingPitch: mountingPitch, isInverted: isCameraInverted)
            ?? Attitude(roll: 0, pitch: 0)
    }

    private var wingtipAttitude: Attitude {
        sample?.wingtipAttitude(
            mountingPitch: mountingPitch,
            isInverted: isCameraInverted
        ) ?? Attitude(roll: 0, pitch: 0)
    }

    var body: some View {
        VStack(spacing: 8) {
            attitudePanel(attitude: attitude, marker: .wings)
            attitudePanel(attitude: wingtipAttitude, marker: .triangle)
        }
    }

    private func attitudePanel(
        attitude: Attitude,
        marker: ArtificialHorizonMarker
    ) -> some View {
        ArtificialHorizonView(
            pitch: attitude.pitch,
            roll: attitude.roll,
            marker: marker
        )
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 140, maxHeight: 140)
    }
}

struct TelemetryTimeline: View {
    let samples: [FlightSample]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isZoomed: Bool
    let window: TimeInterval
    let mountingPitch: Double

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Temps", sample.elapsed),
                    y: .value("Altitude", sample.altitude),
                    series: .value("Mesure", "Altitude")
                )
                .foregroundStyle(.orange)

                LineMark(
                    x: .value("Temps", sample.elapsed),
                    y: .value(
                        "Charge",
                        sample.signedLoadFactor(mountingPitch: mountingPitch) * 1_000
                    ),
                    series: .value("Mesure", "Charge")
                )
                .foregroundStyle(.blue.opacity(0.65))
            }

            RuleMark(x: .value("Position", currentTime))
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXScale(
            domain: isZoomed
                ? max(0, currentTime - window / 2)...min(duration, currentTime + window / 2)
                : 0...max(0.01, duration)
        )
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .frame(minHeight: 100, idealHeight: 120, maxHeight: 150)
        .accessibilityLabel("Chronologie de l’altitude et du facteur de charge")
    }
}

struct PlaybackControls: View {
    let isPlaying: Bool
    let duration: TimeInterval
    let isRecording: Bool
    let onPlayPause: () -> Void
    let onJumpBackward: () -> Void
    let onJumpForward: () -> Void
    let onFineJumpBackward: () -> Void
    let onFineJumpForward: () -> Void
    let onToggleRecording: () -> Void
    let onOpenChaseCam: () -> Void
    let onAddBookmark: () -> Void
    let onPreviousBookmark: () -> Void
    let onNextBookmark: () -> Void
    let onTakeoff: () -> Void
    let onLevelFlight: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onJumpBackward) {
                Label("−10 s", systemImage: "gobackward.10")
            }

            Button(action: onFineJumpBackward) {
                Label("−2 s", systemImage: "backward.fill")
            }

            Button(action: onFineJumpForward) {
                Label("+2 s", systemImage: "forward.fill")
            }

            Button(action: onJumpForward) {
                Label("+10 s", systemImage: "goforward.10")
            }

            Button(action: onPlayPause) {
                Label(isPlaying ? "Pause" : "Lecture", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])

            #if os(macOS)
            Button(action: onToggleRecording) {
                Label(isRecording ? "Arrêter REC" : "REC", systemImage: isRecording ? "stop.fill" : "record.circle")
            }
            .labelStyle(.titleAndIcon)
            .tint(.red)
            #endif

            Button(action: onOpenChaseCam) {
                Label("Cam", systemImage: "map")
            }
            .labelStyle(.titleAndIcon)

            Button(action: onPreviousBookmark) {
                Label("Previous", systemImage: "backward.end.fill")
            }
            .labelStyle(.titleOnly)

            Button(action: onNextBookmark) {
                Label("Next", systemImage: "forward.end.fill")
            }
            .labelStyle(.titleOnly)

            Button(action: onAddBookmark) {
                Label("Bookmark", systemImage: "bookmark.fill")
            }
            .labelStyle(.titleOnly)
            .keyboardShortcut("b", modifiers: .control)

            Button(action: onLevelFlight) {
                Label("Palier", systemImage: "arrow.right.to.line.compact")
            }
            .labelStyle(.titleOnly)

            Button(action: onTakeoff) {
                Label("En ligne", systemImage: "airplane.departure")
            }
            .labelStyle(.titleOnly)

            Spacer()

            Text(duration.clockString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .background {
            PlaybackKeyboardMonitor(
                onJumpBackward: onJumpBackward,
                onJumpForward: onJumpForward,
                onFineJumpBackward: onFineJumpBackward,
                onFineJumpForward: onFineJumpForward,
                onPreviousBookmark: onPreviousBookmark,
                onNextBookmark: onNextBookmark,
                onAddBookmark: onAddBookmark
            )
            .frame(width: 0, height: 0)
        }
        .help("Commandes de lecture")
    }
}

#if os(macOS)
private struct PlaybackKeyboardMonitor: NSViewRepresentable {
    let onJumpBackward: () -> Void
    let onJumpForward: () -> Void
    let onFineJumpBackward: () -> Void
    let onFineJumpForward: () -> Void
    let onPreviousBookmark: () -> Void
    let onNextBookmark: () -> Void
    let onAddBookmark: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var parent: PlaybackKeyboardMonitor
        private var monitor: Any?

        init(parent: PlaybackKeyboardMonitor) {
            self.parent = parent
        }

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      [11, 123, 124].contains(event.keyCode),
                      !(NSApp.keyWindow?.firstResponder is NSTextView) else {
                    return event
                }

                let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
                switch (event.keyCode, modifiers) {
                case (123, []):
                    parent.onJumpBackward()
                case (124, []):
                    parent.onJumpForward()
                case (123, [.shift]):
                    parent.onFineJumpBackward()
                case (124, [.shift]):
                    parent.onFineJumpForward()
                case (123, [.control]):
                    parent.onPreviousBookmark()
                case (124, [.control]):
                    parent.onNextBookmark()
                case (11, [.control]):
                    parent.onAddBookmark()
                default:
                    return event
                }
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}
#else
private struct PlaybackKeyboardMonitor: UIViewRepresentable {
    let onJumpBackward: () -> Void
    let onJumpForward: () -> Void
    let onFineJumpBackward: () -> Void
    let onFineJumpForward: () -> Void
    let onPreviousBookmark: () -> Void
    let onNextBookmark: () -> Void
    let onAddBookmark: () -> Void

    func makeUIView(context: Context) -> UIView {
        UIView(frame: .zero)
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
