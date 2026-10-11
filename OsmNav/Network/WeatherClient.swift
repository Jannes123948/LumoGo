import Foundation

/** Wetter an einem Punkt der Route zur voraussichtlichen Durchfahrtszeit. */
struct RouteWeatherPoint: Hashable {
    let alongMeters: Double
    let time: Date
    let temperature: Double
    /** Regenwahrscheinlichkeit 0…100 (%), nil = nicht geliefert. */
    let precipitationProbability: Int?
    /** Niederschlag in mm in dieser Stunde. */
    let precipitation: Double
    let weatherCode: Int

    var isWet: Bool { (precipitationProbability ?? 0) >= 50 || precipitation >= 0.3 }
}

/** Zusammenfassung fürs Routen-Panel: Wetter am Ziel + erster Regen unterwegs. */
struct RouteWeather: Hashable {
    let points: [RouteWeatherPoint]

    var destination: RouteWeatherPoint? { points.last }
    /** Erster Punkt (außer dem Start) mit Regen/Schnee. */
    var firstWet: RouteWeatherPoint? { points.dropFirst().first(where: \.isWet) ?? (points.first?.isWet == true ? points.first : nil) }

    var minTemperature: Double? { points.map(\.temperature).min() }
    var maxTemperature: Double? { points.map(\.temperature).max() }
}

/** WMO-Wettercode (Open-Meteo) → SF-Symbol + Text. */
enum WeatherCode {
    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return code == 82 || code == 65 ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func text(_ code: Int) -> String {
        switch code {
        case 0: return String(localized: "Sonnig")
        case 1: return String(localized: "Überwiegend sonnig")
        case 2: return String(localized: "Teils bewölkt")
        case 3: return String(localized: "Bewölkt")
        case 45, 48: return String(localized: "Nebel")
        case 51...57: return String(localized: "Nieselregen")
        case 61...67: return code == 66 || code == 67 ? String(localized: "Eisregen") : String(localized: "Regen")
        case 71...77: return String(localized: "Schnee")
        case 80...82: return String(localized: "Regenschauer")
        case 85, 86: return String(localized: "Schneeschauer")
        case 95...99: return String(localized: "Gewitter")
        default: return String(localized: "Bewölkt")
        }
    }
}

/**
 * Wettervorhersage entlang der Route über Open-Meteo (kostenlos, ohne Schlüssel, stündlich). Bis zu
 * 12 Punkte in EINER Anfrage (Koordinatenlisten), je Punkt die Stunde der voraussichtlichen Durchfahrt.
 */
enum WeatherClient {
    private static let session = HTTP.session(requestTimeout: 15)
    private static let maxPoints = 12

    static func forecast(along line: [LatLon], durationSeconds: Double, departure: Date = Date()) async throws -> RouteWeather {
        guard line.count >= 2 else { throw AppError.noResults }
        let cumulative = AlongRouteSearch.cumulativeDistances(line)
        let total = cumulative.last ?? 0
        // Punkte gleichmäßig über die Strecke; kurze Routen brauchen nur Start + Ziel.
        let count = min(maxPoints, max(2, Int(total / 15_000) + 2))
        let samples: [(point: LatLon, along: Double, time: Date)] = (0..<count).map { i in
            let along = total * Double(i) / Double(count - 1)
            let fraction = total > 0 ? along / total : 0
            return (AlongRouteSearch.point(at: along, on: line, cumulative: cumulative), along,
                    departure.addingTimeInterval(durationSeconds * fraction))
        }
        return RouteWeather(points: try await fetch(samples))
    }

    /** Wetter am Standort jetzt und in einer Stunde (Wetter-Knopf). */
    static func here(_ point: LatLon, now: Date = Date()) async throws -> (now: RouteWeatherPoint, inOneHour: RouteWeatherPoint) {
        let points = try await fetch([(point, 0, now), (point, 0, now.addingTimeInterval(3600))])
        guard points.count == 2 else { throw AppError.noResults }
        return (points[0], points[1])
    }

    /** Eine Anfrage für alle Punkte; je Punkt die Stunde, in die seine Zeit fällt. */
    private static func fetch(_ samples: [(point: LatLon, along: Double, time: Date)]) async throws -> [RouteWeatherPoint] {
        let url = HTTP.url("https://api.open-meteo.com/v1/forecast", [
            ("latitude", samples.map { String(format: "%.4f", $0.point.latitude) }.joined(separator: ",")),
            ("longitude", samples.map { String(format: "%.4f", $0.point.longitude) }.joined(separator: ",")),
            ("hourly", "temperature_2m,precipitation_probability,precipitation,weather_code"),
            ("forecast_days", "3"),
            ("timeformat", "unixtime"),
            ("timezone", "auto")
        ])
        let data = try await HTTP.data(session, for: URLRequest(url: url))
        // Mehrere Orte → Array; ein Ort → einzelnes Objekt.
        let forecasts: [Forecast]
        if let many = try? JSONDecoder().decode([Forecast].self, from: data) {
            forecasts = many
        } else if let one = try? JSONDecoder().decode(Forecast.self, from: data) {
            forecasts = [one]
        } else {
            throw AppError.parse
        }
        guard forecasts.count == samples.count else { throw AppError.parse }
        let points = zip(samples, forecasts).compactMap { sample, forecast -> RouteWeatherPoint? in
            let hourly = forecast.hourly
            let target = sample.time.timeIntervalSince1970
            // Stunde, in die die Durchfahrt fällt (nächster Zeitpunkt).
            guard let index = hourly.time.indices.min(by: { abs(Double(hourly.time[$0]) - target) < abs(Double(hourly.time[$1]) - target) }),
                  abs(Double(hourly.time[index]) - target) <= 3600,
                  let temperature = hourly.temperature_2m[index] else { return nil }
            return RouteWeatherPoint(
                alongMeters: sample.along,
                time: sample.time,
                temperature: temperature,
                precipitationProbability: hourly.precipitation_probability?[index] ?? nil,
                precipitation: hourly.precipitation?[index] ?? 0,
                weatherCode: hourly.weather_code?[index] ?? 3
            )
        }
        guard !points.isEmpty else { throw AppError.noResults }
        return points
    }

    private struct Forecast: Decodable {
        let hourly: Hourly
    }

    private struct Hourly: Decodable {
        let time: [Int]
        let temperature_2m: [Double?]
        let precipitation_probability: [Int?]?
        let precipitation: [Double?]?
        let weather_code: [Int?]?
    }
}
