import SwiftUI

struct FlightStatisticsView: View {
    let minimumLoadFactor: Double
    let maximumLoadFactor: Double
    let maximumAltitude: Double
    let videoOffset: TimeInterval
    let currentFrame: Int
    let synchronizationError: TimeInterval

    var body: some View {
        HStack(spacing: 18) {
            StatisticLabel(
                title: "Altitude max.",
                value: maximumAltitude,
                unit: "ft",
                icon: "mountain.2"
            )
            StatisticLabel(
                title: "Charge min.",
                value: minimumLoadFactor,
                unit: "g",
                icon: "arrow.down"
            )
            StatisticLabel(
                title: "Charge max.",
                value: maximumLoadFactor,
                unit: "g",
                icon: "arrow.up"
            )
            StatisticLabel(
                title: "Décalage vidéo",
                value: videoOffset,
                unit: "s",
                icon: "video.badge.clock"
            )
            StatisticLabel(
                title: "Dérive",
                value: synchronizationError * 1_000,
                unit: "ms",
                icon: "arrow.left.arrow.right"
            )
            Label("Image \(currentFrame)", systemImage: "film.stack")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

struct StatisticLabel: View {
    let title: LocalizedStringKey
    let value: Double
    let unit: LocalizedStringKey
    let icon: String

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(title)
                    .foregroundStyle(.secondary)
                Text(value, format: .number.precision(.fractionLength(1)))
                    .monospacedDigit()
                Text(unit)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(.blue)
        }
        .font(.caption)
    }
}
