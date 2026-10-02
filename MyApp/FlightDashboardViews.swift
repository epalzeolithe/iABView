import AVKit
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
    var mountingPitch = 15.0
    var isCameraInverted = false

    var body: some View {
        ZStack {
            VideoPlayer(player: player)
                .background(.black)

            VideoInformationOverlay(
                title: title,
                timestamp: timestamp,
                elapsedTime: elapsedTime,
                previousBookmark: previousBookmark,
                upcomingBookmark: upcomingBookmark
            )

            if showsFlightData, let flightSample {
                FlightVideoDataOverlay(
                    sample: flightSample,
                    mountingPitch: mountingPitch,
                    isCameraInverted: isCameraInverted
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct FlightVideoDataOverlay: View {
    let sample: FlightSample
    let mountingPitch: Double
    let isCameraInverted: Bool

    private var attitude: Attitude {
        sample.attitude(mountingPitch: mountingPitch, isInverted: isCameraInverted)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                VStack(spacing: 4) {
                    metric("IAS", value: sample.indicatedAirspeed, unit: "km/h")
                    metric("GS", value: sample.speed, unit: "km/h")
                }
                Spacer()
                VStack(spacing: 4) {
                    metric("Cap", value: sample.heading, unit: "°")
                    metric("Écart axe", value: aerobaticAxisDeviation, unit: "°")
                    metric("Assiette", value: attitude.pitch, unit: "°")
                    metric("Roulis", value: attitude.roll, unit: "°")
                }
                Spacer()
                metric("Altitude", value: sample.altitude, unit: "ft")
            }

            Spacer()

            HStack(alignment: .bottom) {
                windComponents
                Spacer()
                metric("Vario", value: sample.verticalSpeed, unit: "ft/min")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 42)
        .background {
            VideoAttitudeReticle(attitude: attitude)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Données de vol incrustées")
    }

    private var aerobaticAxisDeviation: Double {
        min(angularDifference(sample.heading, 50), angularDifference(sample.heading, 230))
    }

    private var windComponents: some View {
        let headwindArrow = sample.headwind >= 0 ? "↓" : "↑"
        let crosswindArrow = sample.crosswind > 0 ? "←" : "→"
        let headwind = abs(sample.headwind).formatted(.number.precision(.fractionLength(0)))
        let crosswind = abs(sample.crosswind).formatted(.number.precision(.fractionLength(0)))

        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "\(headwindArrow) \(headwind) kt")
            Text(verbatim: "\(crosswindArrow) \(crosswind) kt")
        }
        .font(.caption.monospacedDigit().bold())
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
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
    let title: LocalizedStringKey
    let timestamp: Date?
    let elapsedTime: TimeInterval
    let previousBookmark: String?
    let upcomingBookmark: String?

    var body: some View {
        VStack {
            HStack(alignment: .top) {
                Text(title)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())

                Spacer()

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
                    .background(.black.opacity(0.65), in: Capsule())
                    .foregroundStyle(.white)
                }
            }

            Spacer()

            if let upcomingBookmark {
                Text(upcomingBookmark)
                    .font(.title3.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.9), in: Capsule())
                    .foregroundStyle(.black)
                    .transition(.scale.combined(with: .opacity))
            }

            HStack(alignment: .bottom) {
                if let previousBookmark {
                    Label(previousBookmark, systemImage: "bookmark.fill")
                        .lineLimit(1)
                }

                Spacer()

                Text(elapsedTime.clockString)
                    .font(.body.monospacedDigit().bold())
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.black.opacity(0.65), in: Capsule())
            .foregroundStyle(.white)
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Map(initialPosition: .automatic) {
                if coordinates.count > 1 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.blue, lineWidth: 3)
                }

                if let sample {
                    Annotation("Avion", coordinate: sample.coordinate) {
                        Image(systemName: "airplane")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(sample.heading - 90))
                            .padding(7)
                            .background(.blue, in: Circle())
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))

            if let sample {
                WindOverlayView(sample: sample, metar: metar)
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct WindOverlayView: View {
    let sample: FlightSample
    let metar: String

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

            if !metar.isEmpty {
                Divider()
                Text(metar)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(9)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Informations de vent et METAR")
    }
}

struct ArtificialHorizonView: View {
    let pitch: Double
    let roll: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Rectangle()
                    .fill(.blue.gradient)
                Rectangle()
                    .fill(.brown.gradient)
                    .frame(height: proxy.size.height)
                    .offset(y: proxy.size.height / 2)
                Rectangle()
                    .fill(.white.opacity(0.9))
                    .frame(height: 2)
                VStack(spacing: 12) {
                    ForEach([-20, -10, 10, 20], id: \.self) { degree in
                        Text("\(abs(degree))°")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
            }
            .rotationEffect(.degrees(-roll))
            .offset(y: pitch * 2)
            .clipped()

            Path { path in
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                path.move(to: CGPoint(x: center.x - 45, y: center.y))
                path.addLine(to: CGPoint(x: center.x - 10, y: center.y))
                path.addLine(to: CGPoint(x: center.x, y: center.y + 8))
                path.addLine(to: CGPoint(x: center.x + 10, y: center.y))
                path.addLine(to: CGPoint(x: center.x + 45, y: center.y))
            }
            .stroke(.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(.primary.opacity(0.7), lineWidth: 4))
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Horizon artificiel")
        .accessibilityValue("Tangage \(pitch, format: .number.precision(.fractionLength(0))) degrés, roulis \(roll, format: .number.precision(.fractionLength(0))) degrés")
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

    var body: some View {
        VStack(spacing: 10) {
            ArtificialHorizonView(
                pitch: attitude.pitch,
                roll: attitude.roll
            )
            .frame(maxHeight: 130)

            AnalogInstrumentsView(
                speed: sample?.speed ?? 0,
                altitude: sample?.altitude ?? 0,
                verticalSpeed: sample?.verticalSpeed ?? 0
            )
            .frame(height: 96)

            LazyVGrid(
                columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ],
                spacing: 6
            ) {
                InstrumentTile(
                    title: "Charge",
                    value: signedLoadFactor,
                    unit: "g",
                    icon: "waveform.path.ecg",
                    tint: .red
                )
                InstrumentTile(
                    title: "Cap",
                    value: sample?.heading ?? 0,
                    unit: "°",
                    icon: "location.north.fill",
                    tint: .purple
                )
                InstrumentTile(
                    title: "Vent",
                    value: sample?.headwind ?? 0,
                    unit: "kt",
                    icon: "wind",
                    tint: .cyan
                )
            }
        }
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
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onPlayPause: () -> Void
    let onJump: (TimeInterval) -> Void
    let onPreviousBookmark: () -> Void
    let onNextBookmark: () -> Void
    let onPreviousFigure: () -> Void
    let onNextFigure: () -> Void
    let onTakeoff: () -> Void
    let onLevelFlight: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlayPause) {
                Label(isPlaying ? "Pause" : "Lecture", systemImage: isPlaying ? "pause.fill" : "play.fill")
            }
            .keyboardShortcut(.space, modifiers: [])

            Button { onJump(-10) } label: {
                Label("10 s", systemImage: "gobackward.10")
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button { onJump(-2) } label: {
                Label("2 s", systemImage: "gobackward")
            }
            .keyboardShortcut(.leftArrow, modifiers: .shift)

            Button(action: onPreviousBookmark) {
                Label("Favori précédent", systemImage: "backward.end.fill")
            }
            .keyboardShortcut(.leftArrow, modifiers: .control)

            Text(currentTime.clockString)
                .font(.body.monospacedDigit())
                .frame(minWidth: 52)

            Button(action: onNextBookmark) {
                Label("Favori suivant", systemImage: "forward.end.fill")
            }
            .keyboardShortcut(.rightArrow, modifiers: .control)

            Button(action: onPreviousFigure) {
                Label("Figure précédente", systemImage: "backward.frame.fill")
            }
            .keyboardShortcut("f", modifiers: .shift)

            Button(action: onNextFigure) {
                Label("Figure suivante", systemImage: "forward.frame.fill")
            }
            .keyboardShortcut("f", modifiers: [])

            Button { onJump(2) } label: {
                Label("2 s", systemImage: "goforward")
            }
            .keyboardShortcut(.rightArrow, modifiers: .shift)

            Button { onJump(10) } label: {
                Label("10 s", systemImage: "goforward.10")
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            Button(action: onTakeoff) {
                Label("Mise en ligne", systemImage: "airplane.departure")
            }
            Button(action: onLevelFlight) {
                Label("Palier suivant", systemImage: "arrow.right.to.line.compact")
            }

            Spacer()

            Text(duration.clockString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .help("Commandes de lecture")
    }
}
