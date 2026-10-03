import MapKit
import SwiftUI

struct ChaseCamView: View {
    let samples: [FlightSample]
    let sample: FlightSample?
    let maximumSpeed: Double

    @State private var cameraPosition: MapCameraPosition = .automatic

    private var coordinates: [CLLocationCoordinate2D] {
        let strideValue = max(1, samples.count / 5_000)
        return samples.enumerated().compactMap { index, value in
            index.isMultiple(of: strideValue) ? value.coordinate : nil
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom, .rotate, .pitch]) {
                if coordinates.count > 1 {
                    MapPolyline(coordinates: coordinates)
                        .stroke(.cyan.opacity(0.8), lineWidth: 4)
                }

                if let sample {
                    Annotation("", coordinate: sample.coordinate) {
                        Image(systemName: "airplane")
                            .font(.title)
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(sample.heading - 90))
                            .padding(8)
                            .background(.red, in: Circle())
                            .shadow(radius: 4)
                    }
                }
            }
            .mapStyle(.hybrid(elevation: .realistic))
            .mapControls {
                #if os(macOS)
                MapZoomStepper()
                #endif
                MapCompass()
                MapScaleView()
                MapPitchToggle()
            }

            if let sample {
                ChaseCamOverlay(sample: sample)
                    .padding()
            }
        }
        .onAppear(perform: updateCamera)
        .onChange(of: sample?.id) {
            updateCamera()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func updateCamera() {
        guard let sample else { return }
        let normalizedSpeed = max(0, min(1, sample.speed / max(1, maximumSpeed)))
        let highSpeedZoomOut = normalizedSpeed * normalizedSpeed * 600
        let speedDistance = 275 + normalizedSpeed * 525 + highSpeedZoomOut
        cameraPosition = .camera(
            MapCamera(
                centerCoordinate: sample.coordinate,
                distance: speedDistance,
                heading: sample.heading,
                pitch: 68
            )
        )
    }
}

struct ChaseCamOverlay: View {
    let sample: FlightSample

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CHASE CAM")
                .font(.caption.bold())
                .foregroundStyle(.cyan)
            Text("\(sample.speed, format: .number.precision(.fractionLength(0))) km/h")
            Text("\(sample.altitude, format: .number.precision(.fractionLength(0))) ft")
            Text("Cap \(sample.heading, format: .number.precision(.fractionLength(0)))°")
        }
        .font(.body.monospacedDigit())
        .padding(10)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}
