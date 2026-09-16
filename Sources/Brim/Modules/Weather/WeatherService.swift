import CoreLocation
import SwiftUI
import Observation

struct WeatherReport: Codable, Equatable {
    struct Current: Codable, Equatable {
        var temperature: Double
        var feelsLike: Double
        var humidity: Double
        var windSpeed: Double
        var code: Int
        var isDay: Bool
    }

    struct Hour: Codable, Equatable {
        var time: Date
        var temperature: Double
        var code: Int
        var isDay: Bool
    }

    struct Day: Codable, Equatable {
        var date: Date
        var code: Int
        var high: Double
        var low: Double
        var rainChance: Int?
    }

    var place: String
    var fetched: Date
    var timeZone: String
    var temperatureUnit: String
    var windUnit: String
    var current: Current
    var hours: [Hour]
    var days: [Day]
}

struct Place: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var region: String?
    var latitude: Double
    var longitude: Double
    var id: String { "\(latitude),\(longitude)" }
    var label: String { [name, region].compactMap { $0 }.joined(separator: ", ") }
}

/// Forecasts from Open-Meteo (free, no key). Uses your location if you allow
/// it, otherwise a city you pick. Refreshes at most every 30 minutes.
@MainActor
@Observable
final class WeatherService {
    static let shared = WeatherService()

    enum Status: Equatable {
        case idle, loading, needsPlace, failed(String)
    }

    private(set) var report: WeatherReport?
    private(set) var status: Status = .idle
    private(set) var locationDenied = false
    /// A city picked by hand. When nil, Brim uses your location.
    private(set) var manualPlace: Place?

    @ObservationIgnored let location = LocationProvider()

    init() {
        report = Storage.load(WeatherReport.self, from: "weather.json")
        manualPlace = Storage.load(Place.self, from: "weather-place.json")
    }

    /// Refreshes only if that can't show a location prompt. Home uses this,
    /// so the prompt only ever comes from the Weather module.
    func refreshIfAllowed() {
        guard manualPlace != nil || location.isAuthorized else { return }
        refreshIfStale()
    }

    func refreshIfStale() {
        guard status != .loading else { return }
        if let report, Date().timeIntervalSince(report.fetched) < 30 * 60 { return }
        refresh()
    }

    func refresh() {
        if let manualPlace {
            Task { await fetch(latitude: manualPlace.latitude, longitude: manualPlace.longitude, place: manualPlace.name) }
            return
        }
        guard !location.isDenied else {
            locationDenied = true
            status = .needsPlace
            return
        }
        status = .loading
        location.requestLocation { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch result {
                    case .success(let coordinate):
                        Task { await self.fetch(latitude: coordinate.latitude, longitude: coordinate.longitude, place: "Current location") }
                    case .failure:
                        self.locationDenied = self.location.isDenied
                        self.status = .needsPlace
                    }
                }
            }
        }
    }

    func choose(_ place: Place?) {
        manualPlace = place
        if let place {
            Storage.save(place, to: "weather-place.json")
        } else {
            try? FileManager.default.removeItem(at: Storage.directory.appendingPathComponent("weather-place.json"))
        }
        report = nil
        refresh()
    }

    func search(_ query: String) async -> [Place] {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "6"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(GeocodingResponse.self, from: data) else { return [] }
        return (response.results ?? []).map {
            Place(name: $0.name, region: [$0.admin1, $0.country].compactMap { $0 }.joined(separator: ", "),
                  latitude: $0.latitude, longitude: $0.longitude)
        }
    }

    private func fetch(latitude: Double, longitude: Double, place: String) async {
        status = .loading
        do {
            let report = try await forecast(latitude: latitude, longitude: longitude, place: place)
            withAnimation(Motion.switchModule) { self.report = report }
            status = .idle
            Storage.save(report, to: "weather.json")
        } catch {
            status = .failed(report == nil ? "Couldn't load the forecast. Check your connection." : "Showing the last forecast. Couldn't refresh.")
        }
    }

    func forecast(latitude: Double, longitude: Double, place: String) async throws -> WeatherReport {
        let usesImperial = Locale.current.measurementSystem == .us
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.3f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.3f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "7"),
            URLQueryItem(name: "forecast_hours", value: "13"),
            URLQueryItem(name: "temperature_unit", value: usesImperial ? "fahrenheit" : "celsius"),
            URLQueryItem(name: "wind_speed_unit", value: usesImperial ? "mph" : "kmh"),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(ForecastResponse.self, from: data).report(place: place)
    }

    #if DEBUG
    func withSample(_ body: () -> Void) {
        let saved = (report, status)
        let now = Date()
        report = WeatherReport(
            place: "Bengaluru", fetched: now, timeZone: "Asia/Kolkata", temperatureUnit: "°C", windUnit: "km/h",
            current: .init(temperature: 24.4, feelsLike: 25.1, humidity: 78, windSpeed: 12, code: 2, isDay: true),
            hours: (0..<13).map { .init(time: now.addingTimeInterval(Double($0) * 3600), temperature: 24 - Double($0) * 0.4,
                                         code: [2, 3, 61, 80, 3, 1][$0 % 6], isDay: $0 < 4) },
            days: (0..<7).map { .init(date: now.addingTimeInterval(Double($0) * 86_400), code: [2, 61, 95, 3, 0, 80, 1][$0],
                                      high: 28 - Double($0 % 3), low: 19 + Double($0 % 2), rainChance: [10, 80, 90, 30, 0, 60, 5][$0]) }
        )
        status = .idle
        body()
        (report, status) = saved
    }
    #endif
}

// MARK: - Weather codes

enum WeatherCode {
    static func symbol(_ code: Int, isDay: Bool = true) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51, 53, 55: "cloud.drizzle.fill"
        case 56, 57, 66, 67: "cloud.sleet.fill"
        case 61, 63: "cloud.rain.fill"
        case 65: "cloud.heavyrain.fill"
        case 71, 73, 75, 77, 85, 86: "cloud.snow.fill"
        case 80, 81: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 82: "cloud.heavyrain.fill"
        case 95, 96, 99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    static func description(_ code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51, 53, 55: "Drizzle"
        case 56, 57: "Freezing drizzle"
        case 61: "Light rain"
        case 63: "Rain"
        case 65: "Heavy rain"
        case 66, 67: "Freezing rain"
        case 71, 73, 75, 77: "Snow"
        case 80, 81: "Showers"
        case 82: "Heavy showers"
        case 85, 86: "Snow showers"
        case 95: "Thunderstorm"
        case 96, 99: "Thunderstorm with hail"
        default: "—"
        }
    }
}

// MARK: - Open-Meteo responses

private struct ForecastResponse: Decodable {
    struct Units: Decodable {
        let temperature_2m: String
        let wind_speed_10m: String?
    }
    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let relative_humidity_2m: Double
        let weather_code: Int
        let is_day: Int
        let wind_speed_10m: Double
    }
    struct Hourly: Decodable {
        let time: [Double]
        let temperature_2m: [Double?]
        let weather_code: [Int?]
        let is_day: [Int?]
    }
    struct Daily: Decodable {
        let time: [Double]
        let weather_code: [Int?]
        let temperature_2m_max: [Double?]
        let temperature_2m_min: [Double?]
        let precipitation_probability_max: [Int?]?
    }

    let timezone: String
    let current_units: Units
    let current: Current
    let hourly: Hourly
    let daily: Daily

    func report(place: String) -> WeatherReport {
        let hours = hourly.time.indices.compactMap { index -> WeatherReport.Hour? in
            guard let temperature = hourly.temperature_2m[index], let code = hourly.weather_code[index] else { return nil }
            return .init(time: Date(timeIntervalSince1970: hourly.time[index]), temperature: temperature,
                         code: code, isDay: (hourly.is_day[index] ?? 1) == 1)
        }
        let days = daily.time.indices.compactMap { index -> WeatherReport.Day? in
            guard let code = daily.weather_code[index], let high = daily.temperature_2m_max[index],
                  let low = daily.temperature_2m_min[index] else { return nil }
            return .init(date: Date(timeIntervalSince1970: daily.time[index]), code: code, high: high, low: low,
                         rainChance: daily.precipitation_probability_max?[index])
        }
        return WeatherReport(
            place: place, fetched: Date(), timeZone: timezone,
            temperatureUnit: current_units.temperature_2m, windUnit: current_units.wind_speed_10m ?? "km/h",
            current: .init(temperature: current.temperature_2m, feelsLike: current.apparent_temperature,
                           humidity: current.relative_humidity_2m, windSpeed: current.wind_speed_10m,
                           code: current.weather_code, isDay: current.is_day == 1),
            hours: hours, days: days
        )
    }
}

private struct GeocodingResponse: Decodable {
    struct Result: Decodable {
        let name: String
        let latitude: Double
        let longitude: Double
        let country: String?
        let admin1: String?
    }
    let results: [Result]?
}

// MARK: - Location

/// One-shot location lookups. Lives outside the main actor because
/// CLLocationManager's delegate callbacks aren't isolated.
final class LocationProvider: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    typealias Completion = @Sendable (Result<CLLocationCoordinate2D, Error>) -> Void

    private let manager = CLLocationManager()
    private var pending: [Completion] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var statusDescription: String {
        "status=\(manager.authorizationStatus.rawValue) servicesEnabled=\(CLLocationManager.locationServicesEnabled())"
    }

    var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: true
        default: false
        }
    }

    var isDenied: Bool {
        switch manager.authorizationStatus {
        case .denied, .restricted: true
        default: !CLLocationManager.locationServicesEnabled()
        }
    }

    /// Call on the main thread.
    func requestLocation(_ completion: @escaping Completion) {
        pending.append(completion)
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        default:
            finish(.failure(CLError(.denied)))
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !pending.isEmpty else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .notDetermined:
            break
        default:
            finish(.failure(CLError(.denied)))
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        finish(.success(coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        let callbacks = pending
        pending.removeAll()
        callbacks.forEach { $0(result) }
    }
}
