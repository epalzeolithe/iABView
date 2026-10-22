import SwiftUI

struct BookmarkTimelineSlider: View {
    @Binding var value: TimeInterval
    let duration: TimeInterval
    let bookmarks: [FlightBookmark]
    let videoFrameRate: Double

    var body: some View {
        VStack(spacing: 0) {
            Slider(value: $value, in: 0...max(0.01, duration))

            GeometryReader { proxy in
                Canvas { context, size in
                    for bookmark in bookmarks {
                        let bookmarkTime = Double(bookmark.frame) / max(1, videoFrameRate)
                        guard bookmarkTime >= 0, bookmarkTime <= duration else { continue }
                        let x = bookmarkTime / max(0.01, duration) * size.width
                        context.fill(
                            Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)),
                            with: .color(.secondary)
                        )
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(.leading, 54)
        .accessibilityLabel("Position dans le vol")
    }
}

struct CompactTelemetryStrips: View {
    let samples: [FlightSample]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isZoomed: Bool
    let mountingPitch: Double
    let maximumAltitude: Double
    let bookmarks: [FlightBookmark]
    let videoFrameRate: Double

    private var visibleRange: ClosedRange<TimeInterval> {
        let fullRange = 0...max(0.01, duration)
        guard isZoomed,
              let firstBoxSample = samples.first(where: { $0.altitude > 3_000 }),
              let lastBoxSample = samples.last(where: { $0.altitude > 3_000 }) else {
            return fullRange
        }

        let boxRange = firstBoxSample.elapsed...max(
            firstBoxSample.elapsed + 0.01,
            lastBoxSample.elapsed
        )
        return boxRange
    }

    var body: some View {
        VStack(spacing: 3) {
            strip(metric: .gForce(mountingPitch: mountingPitch))
            strip(metric: .altitude(maximumAltitude: maximumAltitude))
            strip(metric: .verticalSpeed)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Frises de facteur de charge, altitude et vitesse verticale")
    }

    private func strip(metric: TelemetryMetric) -> some View {
        HStack(spacing: 6) {
            Text(metric.title)
                .font(.system(size: 9, design: .monospaced))
                .frame(width: 48, alignment: .trailing)

            GeometryReader { _ in
                ZStack {
                    // Rebuilding every bar (one `context.fill` per sample, up to
                    // ~2 500 of them for the whole flight) is the expensive part
                    // here, yet the bars themselves never change while playing —
                    // only the cursor below does. `.equatable()` lets SwiftUI skip
                    // re-invoking this Canvas on the ~30 Hz ticks where `samples`
                    // and `visibleRange` are unchanged, instead of redrawing all
                    // three strips' worth of bars every tick just to move a line.
                    TelemetryStripBackground(samples: samples, range: visibleRange, metric: metric)
                        .equatable()
                    TelemetryStripCursor(currentTime: currentTime, range: visibleRange)
                }
            }
        }
    }
}

private enum TelemetryMetric: Equatable {
    case gForce(mountingPitch: Double)
    case altitude(maximumAltitude: Double)
    case verticalSpeed

    var title: LocalizedStringKey {
        switch self {
        case .gForce: "GForce"
        case .altitude: "Alt"
        case .verticalSpeed: "Vario"
        }
    }

    func value(for sample: FlightSample) -> Double {
        switch self {
        case .gForce(let mountingPitch):
            sample.signedLoadFactor(mountingPitch: mountingPitch)
        case .altitude:
            sample.altitude
        case .verticalSpeed:
            sample.verticalSpeed
        }
    }

    func color(for value: Double) -> Color {
        switch self {
        case .gForce:
            if value < 0.8 { return .blue }
            if value > 2 { return .red }
            let error = min(abs(value - 1), 1)
            return Color(red: error, green: 1 - error, blue: max(value - 2, 0) / 2)
        case .altitude(let maximumAltitude):
            let normalized = max(0, min(1, value / max(1, maximumAltitude)))
            return Color(hue: 0.62 - normalized * 0.62, saturation: 0.85, brightness: 0.95)
        case .verticalSpeed:
            if value > 150 { return .green }
            if value < -150 { return .red }
            return .gray
        }
    }
}

private struct TelemetryStripBackground: View, Equatable {
    let samples: [FlightSample]
    let range: ClosedRange<TimeInterval>
    let metric: TelemetryMetric

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.samples.count == rhs.samples.count
            && lhs.samples.first?.elapsed == rhs.samples.first?.elapsed
            && lhs.samples.last?.elapsed == rhs.samples.last?.elapsed
            && lhs.range == rhs.range
            && lhs.metric == rhs.metric
    }

    var body: some View {
        Canvas { context, size in
            let span = max(0.01, range.upperBound - range.lowerBound)
            let visibleSamples = samples.filter { range.contains($0.elapsed) }
            guard !visibleSamples.isEmpty else { return }
            let stripInset: CGFloat = 2
            let stripHeight = max(1, size.height - stripInset * 2)

            context.fill(
                Path(
                    CGRect(x: 0, y: stripInset, width: size.width, height: stripHeight)
                ),
                with: .color(.gray.opacity(0.22))
            )

            for (index, sample) in visibleSamples.enumerated() {
                let startX = (sample.elapsed - range.lowerBound) / span * size.width
                let endTime = index + 1 < visibleSamples.count
                    ? visibleSamples[index + 1].elapsed
                    : sample.elapsed + span / Double(max(1, visibleSamples.count))
                let endX = (endTime - range.lowerBound) / span * size.width
                context.fill(
                    Path(
                        CGRect(
                            x: startX,
                            y: stripInset,
                            width: max(1, endX - startX),
                            height: stripHeight
                        )
                    ),
                    with: .color(metric.color(for: metric.value(for: sample)))
                )
            }
        }
    }
}

private struct TelemetryStripCursor: View {
    let currentTime: TimeInterval
    let range: ClosedRange<TimeInterval>

    var body: some View {
        Canvas { context, size in
            let span = max(0.01, range.upperBound - range.lowerBound)
            let cursorX = (currentTime - range.lowerBound) / span * size.width
            context.fill(
                Path(CGRect(x: cursorX - 1.5, y: 0, width: 3, height: size.height)),
                with: .color(.black)
            )
        }
    }
}
