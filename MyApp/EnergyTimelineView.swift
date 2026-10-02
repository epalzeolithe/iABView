import Charts
import SwiftUI

struct EnergyTimelineView: View {
    let samples: [FlightSample]
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isZoomed: Bool
    let window: TimeInterval

    private var domain: ClosedRange<TimeInterval> {
        guard isZoomed else { return 0...max(0.01, duration) }
        let halfWindow = window / 2
        return max(0, currentTime - halfWindow)...min(
            duration,
            currentTime + halfWindow
        )
    }

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(
                    x: .value("Temps", sample.elapsed),
                    y: .value("Énergie", sample.energy)
                )
                .foregroundStyle(.green)
                .interpolationMethod(.linear)
            }

            RuleMark(x: .value("Position", currentTime))
                .foregroundStyle(.red)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartXScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .chartPlotStyle { plot in
            plot.background(.green.opacity(0.06))
        }
        .frame(height: 82)
        .overlay(alignment: .topLeading) {
            Label("Énergie", systemImage: "bolt.fill")
                .font(.caption.bold())
                .foregroundStyle(.green)
                .padding(6)
        }
        .accessibilityLabel("Évolution de l’énergie du vol")
    }
}
