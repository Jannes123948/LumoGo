import SwiftUI

/** Wetter-Knopf: hier jetzt und in einer Stunde, dazu das Wetter entlang der (restlichen) Strecke. */
struct WeatherSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var here: (now: RouteWeatherPoint, inOneHour: RouteWeatherPoint)?
    @State private var hereError: String?
    @State private var route: RouteWeather?
    @State private var routeError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let here {
                        WeatherPointRow(title: "Jetzt", point: here.now)
                        WeatherPointRow(title: "In 1 Stunde", point: here.inOneHour)
                    } else if let hereError {
                        Text(hereError).foregroundStyle(.secondary)
                    } else {
                        loadingRow
                    }
                } header: {
                    Text("Hier")
                }

                if model.weatherRoute() != nil || route != nil {
                    Section {
                        if let route {
                            ForEach(Array(route.points.enumerated()), id: \.offset) { index, point in
                                WeatherPointRow(title: title(index, count: route.points.count, point: point), point: point, showTime: true)
                            }
                        } else if let routeError {
                            Text(routeError).foregroundStyle(.secondary)
                        } else {
                            loadingRow
                        }
                    } header: {
                        Text(model.navigationActive ? "Auf der restlichen Strecke" : "Auf der Strecke")
                    } footer: {
                        Text("Jeweils zur voraussichtlichen Durchfahrtszeit. Daten: Open-Meteo.")
                    }
                }
            }
            .navigationTitle("Wetter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .refreshable { await load() }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private var loadingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Wird geladen …").foregroundStyle(.secondary)
        }
    }

    private func title(_ index: Int, count: Int, point: RouteWeatherPoint) -> String {
        if index == 0 { return model.navigationActive ? "Hier" : "Start" }
        if index == count - 1 { return "Am Ziel" }
        return "km \(Int((point.alongMeters / 1000).rounded()))"
    }

    private func load() async {
        hereError = nil
        routeError = nil
        let position = model.currentPosition
        let routeInfo = model.weatherRoute()
        async let hereResult: Result<(now: RouteWeatherPoint, inOneHour: RouteWeatherPoint), Error>? = {
            guard let position else { return nil }
            do { return .success(try await WeatherClient.here(position)) } catch { return .failure(error) }
        }()
        async let routeResult: Result<RouteWeather, Error>? = {
            guard let routeInfo else { return nil }
            do { return .success(try await WeatherClient.forecast(along: routeInfo.line, durationSeconds: routeInfo.duration)) } catch { return .failure(error) }
        }()
        switch await hereResult {
        case .success(let value): here = value
        case .failure: hereError = "Wetter konnte nicht geladen werden."
        case nil: hereError = "Standort noch nicht verfügbar."
        }
        switch await routeResult {
        case .success(let value): route = value
        case .failure: routeError = "Wetter auf der Strecke konnte nicht geladen werden."
        case nil: route = nil
        }
    }
}

/** Eine Zeile: Symbol, Bezeichnung (+ Uhrzeit), Wettertext, Temperatur, Regenwahrscheinlichkeit. */
struct WeatherPointRow: View {
    let title: String
    let point: RouteWeatherPoint
    var showTime = false

    var body: some View {
        HStack(spacing: 12) {
            WeatherBadge(code: point.weatherCode, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(showTime ? "\(title) · \(point.time.formatted(date: .omitted, time: .shortened))" : title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(point.isWet ? Color.orange : .secondary)
            }
            Spacer(minLength: 0)
            Text("\(Int(point.temperature.rounded()))°")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var parts = [WeatherCode.text(point.weatherCode)]
        if let probability = point.precipitationProbability { parts.append("Regen \(probability) %") }
        if point.precipitation >= 0.1 {
            parts.append(String(format: "%.1f mm", point.precipitation).replacingOccurrences(of: ".", with: ","))
        }
        return parts.joined(separator: " · ")
    }
}

/**
 * Wettersymbol auf blauem „Himmel“: mehrfarbige SF-Symbole haben WEISSE Wolken — auf hellem
 * Hintergrund unsichtbar (Nutzermeldung „die Wettersymbole fehlen“).
 */
struct WeatherBadge: View {
    let code: Int
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: WeatherCode.symbol(code))
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.80), Color(red: 0.22, green: 0.38, blue: 0.62)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
    }
}
