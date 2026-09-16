import SwiftUI

@MainActor
final class WeatherModule: NotchModule {
    let id = "weather"
    let title = "Weather"
    let symbol = "cloud.sun"
    func expandedView() -> AnyView { AnyView(WeatherView()) }
}

private struct WeatherView: View {
    @State private var choosingPlace = false
    private var weather: WeatherService { .shared }

    var body: some View {
        Group {
            if choosingPlace || (weather.report == nil && weather.status == .needsPlace) {
                PlacePicker(canUseLocation: !weather.locationDenied) { choosingPlace = false }
            } else if let report = weather.report {
                ForecastView(report: report, status: weather.status) { choosingPlace = true }
            } else if case .failed(let message) = weather.status {
                EmptyStateView(symbol: "wifi.exclamationmark", title: "No forecast", message: message,
                               buttonTitle: "Try again") { weather.refresh() }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { weather.refreshIfStale() }
    }
}

private struct ForecastView: View {
    let report: WeatherReport
    let status: WeatherService.Status
    let changePlace: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: WeatherCode.symbol(report.current.code, isDay: report.current.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 34))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(temperature(report.current.temperature))
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                        Text(WeatherCode.description(report.current.code))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Button(action: changePlace) {
                        HStack(spacing: 4) {
                            Image(systemName: report.place == "Current location" ? "location.fill" : "mappin")
                            Text(report.place).lineLimit(1)
                        }
                        .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .help("Change place")
                    Text("Feels like \(temperature(report.current.feelsLike))")
                    Text("Humidity \(Int(report.current.humidity))% · Wind \(Int(report.current.windSpeed.rounded())) \(report.windUnit)")
                    Text(statusText)
                        .foregroundStyle(status == .idle ? Theme.tertiaryInk : Theme.accent)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 0) {
                ForEach(Array(report.hours.enumerated().filter { $0.offset % 2 == 0 }.prefix(7)), id: \.offset) { index, hour in
                    VStack(spacing: 4) {
                        Text(index == 0 ? "Now" : hour.time.formatted(hourFormat))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.secondaryInk)
                        Image(systemName: WeatherCode.symbol(hour.code, isDay: hour.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 15))
                            .frame(height: 18)
                        Text(temperature(hour.temperature))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 6)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 0) {
                ForEach(Array(report.days.prefix(7).enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 2) {
                        Text(index == 0 ? "Today" : day.date.formatted(dayFormat))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.secondaryInk)
                        Image(systemName: WeatherCode.symbol(day.code))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 13))
                            .frame(height: 16)
                        Text("\(degrees(day.high)) \(degrees(day.low))")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                        if let chance = day.rainChance, chance >= 20 {
                            Text("\(chance)%")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
    }

    private var hourFormat: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.hour()
        style.timeZone = TimeZone(identifier: report.timeZone) ?? .current
        return style
    }

    private var dayFormat: Date.FormatStyle {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated)
        style.timeZone = TimeZone(identifier: report.timeZone) ?? .current
        return style
    }

    private var statusText: String {
        switch status {
        case .loading: "Updating…"
        case .failed(let message): message
        default: "Updated " + Format.relative(report.fetched)
        }
    }

    private func temperature(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    private func degrees(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }
}

private struct PlacePicker: View {
    let canUseLocation: Bool
    let done: () -> Void
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var searching = false
    private var weather: WeatherService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(canUseLocation ? "Where should the forecast be for?" : "Pick a city for the forecast")
                .font(.system(size: 15, weight: .semibold))
            if !canUseLocation {
                Text("Location access is off, so choose a city instead. You can turn location on in Privacy & Security.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryInk)
            }
            HStack(spacing: 8) {
                NotchSearchField(placeholder: "City name", text: $query, onSubmit: search)
                Button("Search", action: search)
                    .buttonStyle(PillButtonStyle())
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                if canUseLocation {
                    Button { weather.choose(nil); done() } label: { Label("Use my location", systemImage: "location.fill") }
                        .buttonStyle(PillButtonStyle(prominent: false))
                } else {
                    Button("Open Privacy Settings") { PrivacyPane.location.open() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                }
            }
            if searching {
                ProgressView().controlSize(.small)
            }
            NotchScroll {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { place in
                        Button {
                            weather.choose(place)
                            done()
                        } label: {
                            HStack {
                                Text(place.name).font(.system(size: 13, weight: .medium))
                                Text(place.region ?? "").font(.system(size: 11)).foregroundStyle(Theme.secondaryInk)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(HoverButtonStyle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        searching = true
        Task {
            results = await weather.search(text)
            searching = false
        }
    }
}
