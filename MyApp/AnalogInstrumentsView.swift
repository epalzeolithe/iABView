import SwiftUI

struct AnalogInstrumentsView: View {
    let speed: Double
    let altitude: Double
    let verticalSpeed: Double

    var body: some View {
        HStack(spacing: 8) {
            AirspeedIndicator(speed: speed)
            AltimeterIndicator(altitude: altitude)
            VerticalSpeedIndicator(verticalSpeed: verticalSpeed)
        }
    }
}

struct AirspeedIndicator: View {
    let speed: Double

    private var needleAngle: Double {
        max(0, min(360, speed)) / 360 * 340 - 135
    }

    var body: some View {
        ZStack {
            DialBackground()
            Circle()
                .trim(from: 0, to: 300 / 360)
                .stroke(.green, style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                .rotationEffect(.degrees(-225))
                .padding(7)
            Circle()
                .trim(from: 300 / 360, to: 340 / 360)
                .stroke(.yellow, lineWidth: 5)
                .rotationEffect(.degrees(-225))
                .padding(7)
            Circle()
                .trim(from: 340 / 360, to: 1)
                .stroke(.red, lineWidth: 5)
                .rotationEffect(.degrees(-225))
                .padding(7)
            DialTicks(count: 36, majorEvery: 5)
            Needle(angle: needleAngle)
            DialCaption(title: "BADIN", value: speed, unit: "km/h")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Badin")
        .accessibilityValue("\(speed, format: .number.precision(.fractionLength(0))) kilomètres heure")
    }
}

struct AltimeterIndicator: View {
    let altitude: Double

    private var hundredsAngle: Double {
        (altitude.truncatingRemainder(dividingBy: 1_000) / 1_000) * 360 - 90
    }

    private var thousandsAngle: Double {
        ((altitude / 1_000).truncatingRemainder(dividingBy: 10) / 10) * 360 - 90
    }

    var body: some View {
        ZStack {
            DialBackground()
            DialTicks(count: 10, majorEvery: 1)
            Needle(angle: hundredsAngle, length: 0.38, width: 2)
            Needle(angle: thousandsAngle, length: 0.27, width: 5)
            DialCaption(title: "ALT", value: altitude, unit: "ft")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Altimètre")
        .accessibilityValue("\(altitude, format: .number.precision(.fractionLength(0))) pieds")
    }
}

struct VerticalSpeedIndicator: View {
    let verticalSpeed: Double

    private var needleAngle: Double {
        180 + max(-2_000, min(2_000, verticalSpeed)) / 2_000 * 120
    }

    var body: some View {
        ZStack {
            DialBackground()
            ForEach([-2_000, -1_000, 0, 1_000, 2_000], id: \.self) { value in
                VarioTick(value: value)
            }
            Needle(angle: needleAngle, length: 0.36, width: 3)
            DialCaption(title: "VARIO", value: verticalSpeed, unit: "ft/min")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Variomètre")
        .accessibilityValue("\(verticalSpeed, format: .number.precision(.fractionLength(0))) pieds par minute")
    }
}

private struct DialBackground: View {
    var body: some View {
        Circle()
            .fill(.black.opacity(0.82))
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
    }
}

private struct DialTicks: View {
    let count: Int
    let majorEvery: Int

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { index in
                Rectangle()
                    .fill(.white)
                    .frame(
                        width: index.isMultiple(of: majorEvery) ? 2 : 1,
                        height: index.isMultiple(of: majorEvery) ? 8 : 5
                    )
                    .offset(y: -38)
                    .rotationEffect(.degrees(Double(index) / Double(count) * 360))
            }
        }
    }
}

private struct Needle: View {
    let angle: Double
    var length = 0.36
    var width: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let radius = min(proxy.size.width, proxy.size.height)
            Path { path in
                let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                path.move(to: center)
                path.addLine(
                    to: CGPoint(
                        x: center.x + radius * length,
                        y: center.y
                    )
                )
            }
            .stroke(.white, style: StrokeStyle(lineWidth: width, lineCap: .round))
            .rotationEffect(.degrees(angle), anchor: .center)
        }
    }
}

private struct DialCaption: View {
    let title: LocalizedStringKey
    let value: Double
    let unit: LocalizedStringKey

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(title)
                .font(.system(size: 7, weight: .bold))
            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.system(size: 9, design: .monospaced))
            Text(unit)
                .font(.system(size: 6))
        }
        .foregroundStyle(.white)
        .padding(.bottom, 9)
    }
}

private struct VarioTick: View {
    let value: Int

    private var angle: Double {
        180 + Double(value) / 2_000 * 120
    }

    var body: some View {
        Rectangle()
            .fill(.white)
            .frame(width: 8, height: 2)
            .offset(x: -35)
            .rotationEffect(.degrees(angle))
    }
}
