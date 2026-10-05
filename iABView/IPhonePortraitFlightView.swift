import SwiftUI

#if os(iOS)
struct IPhonePortraitFlightView: View {
    let model: FlightViewModel
    let onAddBookmark: () -> Void
    let onOpenFullScreen: (FlightVideoSelection) -> Void

    @State private var selectedVideo = FlightVideoSelection.front

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                videoCarousel
                    .frame(height: 220)

                aircraftSection
                    .frame(height: 210)

                loadFactorBar

                timeline

                compactControls
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private var videoCarousel: some View {
        TabView(selection: $selectedVideo) {
            videoPane(for: .front)
                .tag(FlightVideoSelection.front)

            videoPane(for: .back)
                .tag(FlightVideoSelection.back)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Choix de la caméra")
        .accessibilityHint("Balayez vers la gauche ou la droite pour changer de caméra")
    }

    @ViewBuilder
    private func videoPane(for selection: FlightVideoSelection) -> some View {
        let isFront = selection == .front
        VideoPane(
            title: isFront ? "Caméra avant" : "Caméra arrière",
            player: isFront ? model.displayedFrontPlayer : model.displayedBackPlayer,
            timestamp: model.currentSample?.timestamp,
            elapsedTime: model.currentTime,
            previousBookmark: model.previousBookmarkName,
            upcomingBookmark: model.upcomingBookmarkName,
            flightSample: model.currentSample,
            showsFlightData: isFront,
            timestampAlignment: .bottomTrailing,
            mountingPitch: model.mountingPitch,
            isCameraInverted: model.isCameraInverted,
            overlayStyle: .headingOnly
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenFullScreen(selection)
        }
    }

    private var aircraftSection: some View {
        let attitude = model.currentSample?.attitude(
            mountingPitch: model.mountingPitch,
            isInverted: model.isCameraInverted
        )

        return ZStack(alignment: .topTrailing) {
            Aircraft3DView(
                quaternionW: model.renderingSample?.quaternionW ?? 1,
                quaternionX: model.renderingSample?.quaternionX ?? 0,
                quaternionY: model.renderingSample?.quaternionY ?? 0,
                quaternionZ: model.renderingSample?.quaternionZ ?? 0,
                modelURL: model.aircraftModelURL,
                mountingPitch: model.mountingPitch,
                isInverted: model.isCameraInverted,
                showsAxes: model.shows3DAxes,
                showsVerticalGrid: model.showsVerticalGrid,
                showsTrajectoryTrail: model.showsTrajectoryTrail,
                accelerationX: model.renderingSample?.accelerationX ?? 0,
                accelerationY: model.renderingSample?.accelerationY ?? 0,
                accelerationZ: model.renderingSample?.accelerationZ ?? 0,
                speed: model.renderingSample?.speed ?? 0,
                samples: model.samples,
                player: model.frontPlayer
            )

            VStack(alignment: .trailing, spacing: 3) {
                metric("Vitesse", value: model.currentSample?.speed ?? 0, unit: "km/h")
                metric("Altitude", value: model.currentSample?.altitude ?? 0, unit: "ft")
                metric("Vario", value: model.currentSample?.verticalSpeed ?? 0, unit: "ft/min")
                metric("Tangage", value: attitude?.pitch ?? 0, unit: "°")
                metric("Roulis", value: attitude?.roll ?? 0, unit: "°")
            }
            .padding(7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .padding(8)

        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modèle 3D et données de vol")
    }

    private func metric(_ title: LocalizedStringKey, value: Double, unit: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(0)))
                .fontWeight(.semibold)
            Text(unit)
                .foregroundStyle(.secondary)
        }
        .font(.caption.monospacedDigit())
    }

    private var loadFactorBar: some View {
        VStack(spacing: 3) {
            HStack {
                Label("Facteur de charge", systemImage: "gauge.with.dots.needle.67percent")
                Spacer()
                Text(model.currentSignedLoadFactor, format: .number.precision(.fractionLength(1)))
                    .font(.headline.monospacedDigit())
                Text("G")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            GeometryReader { proxy in
                let range = -3.0...8.0
                let clampedValue = min(range.upperBound, max(range.lowerBound, model.currentSignedLoadFactor))
                let progress = (clampedValue - range.lowerBound) / (range.upperBound - range.lowerBound)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .green, .yellow, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Circle()
                        .fill(.white)
                        .stroke(.black.opacity(0.55), lineWidth: 1)
                        .frame(width: 14, height: 14)
                        .offset(x: max(0, proxy.size.width * progress - 7))
                }
            }
            .frame(height: 14)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Facteur de charge")
        .accessibilityValue("\(model.currentSignedLoadFactor, format: .number.precision(.fractionLength(1))) G")
    }

    private var timeline: some View {
        HStack(spacing: 6) {
            Text(model.currentTime.clockString)
            BookmarkTimelineSlider(
                value: Binding(
                    get: { model.currentTime },
                    set: model.seek
                ),
                duration: model.duration,
                bookmarks: model.bookmarks,
                videoFrameRate: model.frontVideoFrameRate
            )
            Text(model.duration.clockString)
        }
        .font(.caption2.monospacedDigit())
        .frame(height: 34)
    }

    private var compactControls: some View {
        VStack(spacing: 6) {
            HStack {
                control("Reculer de 10 secondes", symbol: "gobackward.10") { model.jump(by: -10) }
                control("Reculer de 2 secondes", symbol: "backward.fill") { model.jump(by: -2) }
                control(
                    model.isPlaying ? "Pause" : "Lecture",
                    symbol: model.isPlaying ? "pause.fill" : "play.fill",
                    prominent: true,
                    action: model.togglePlayback
                )
                control("Avancer de 2 secondes", symbol: "forward.fill") { model.jump(by: 2) }
                control("Avancer de 10 secondes", symbol: "goforward.10") { model.jump(by: 10) }
            }

            HStack {
                control("Bookmark précédent", symbol: "backward.end.fill", action: model.previousBookmark)
                control("Bookmark suivant", symbol: "forward.end.fill", action: model.nextBookmark)
                control("Ajouter un bookmark", symbol: "bookmark.fill", action: onAddBookmark)
                control("Mise en ligne", symbol: "airplane.departure", action: model.goToTakeoff)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func control(
        _ label: LocalizedStringKey,
        symbol: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .tint(prominent ? .accentColor : nil)
        .accessibilityLabel(label)
    }
}

struct IPhoneLandscapeFlightView: View {
    let model: FlightViewModel
    let onAddBookmark: () -> Void
    let onOpenFullScreen: (FlightVideoSelection) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                videoPane(for: .front)
                videoPane(for: .back)
            }
            .frame(maxHeight: .infinity)

            timeline
            compactControls
        }
        .padding(6)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func videoPane(for selection: FlightVideoSelection) -> some View {
        let isFront = selection == .front

        return VideoPane(
            title: isFront ? "Caméra avant" : "Caméra arrière",
            player: isFront ? model.displayedFrontPlayer : model.displayedBackPlayer,
            timestamp: nil,
            elapsedTime: model.currentTime,
            previousBookmark: model.previousBookmarkName,
            upcomingBookmark: model.upcomingBookmarkName,
            flightSample: model.currentSample,
            showsFlightData: isFront,
            timestampAlignment: .bottomTrailing,
            mountingPitch: model.mountingPitch,
            isCameraInverted: model.isCameraInverted,
            overlayStyle: .headingOnly
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onOpenFullScreen(selection)
        }
    }

    private var timeline: some View {
        HStack(spacing: 6) {
            Text(model.currentTime.clockString)
            BookmarkTimelineSlider(
                value: Binding(
                    get: { model.currentTime },
                    set: model.seek
                ),
                duration: model.duration,
                bookmarks: model.bookmarks,
                videoFrameRate: model.frontVideoFrameRate
            )
            Text(model.duration.clockString)
        }
        .font(.caption2.monospacedDigit())
        .frame(height: 24)
    }

    private var compactControls: some View {
        HStack(spacing: 6) {
            control("Reculer de 10 secondes", symbol: "gobackward.10") { model.jump(by: -10) }
            control("Reculer de 2 secondes", symbol: "backward.fill") { model.jump(by: -2) }
            control(
                model.isPlaying ? "Pause" : "Lecture",
                symbol: model.isPlaying ? "pause.fill" : "play.fill",
                prominent: true,
                action: model.togglePlayback
            )
            control("Avancer de 2 secondes", symbol: "forward.fill") { model.jump(by: 2) }
            control("Avancer de 10 secondes", symbol: "goforward.10") { model.jump(by: 10) }
            control("Bookmark précédent", symbol: "backward.end.fill", action: model.previousBookmark)
            control("Bookmark suivant", symbol: "forward.end.fill", action: model.nextBookmark)
            control("Ajouter un bookmark", symbol: "bookmark.fill", action: onAddBookmark)
            control("Mise en ligne", symbol: "airplane.departure", action: model.goToTakeoff)
        }
    }

    private func control(
        _ label: LocalizedStringKey,
        symbol: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(prominent ? .accentColor : nil)
        .accessibilityLabel(label)
    }
}
#endif
