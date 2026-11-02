import SwiftUI
import Charts

/** Kennzahlen des Fahrtenbuchs: Summen, km je Woche, Rekorde, häufige Ziele, CSV-Export. */
struct TripStatsSection: View {
    let trips: [Trip]
    @State private var csvFile: URL?
    @State private var period = TripStats.Period.weeks
    @State private var metric = TripStats.Metric.km

    var body: some View {
        let stats = TripStats(trips: trips)
        Section {
            HStack(spacing: 0) {
                statTile(String(localized: "\(stats.count)"), String(localized: "Fahrten"))
                statTile(FormatUtils.formatDistance(stats.totalMeters), String(localized: "gesamt"))
                statTile(FormatUtils.formatDuration(stats.totalSeconds), String(localized: "unterwegs"))
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Picker("Zeitraum", selection: $period) {
                    ForEach(TripStats.Period.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Kennzahl", selection: $metric) {
                    ForEach(TripStats.Metric.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                let buckets = stats.buckets(period)
                Chart(buckets) { bucket in
                    BarMark(x: .value("Zeitraum", bucket.start, unit: period.component), y: .value(metric.label, bucket.value(metric)))
                        .foregroundStyle(Color.accentColor.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: period.component, count: period == .weeks ? 1 : 2)) { _ in
                        AxisValueLabel(format: period == .weeks ? .dateTime.day().month(.defaultDigits) : .dateTime.month(.abbreviated), centered: true)
                    }
                }
                .frame(height: 140)
                Text(metric.unitNote).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            row(String(localized: "Ø pro Fahrt"), "\(FormatUtils.formatDistance(stats.averageMeters)) · \(FormatUtils.formatDuration(stats.averageSeconds))")
            if let speed = stats.averageKmh {
                row(String(localized: "Ø Geschwindigkeit"), String(localized: "\(Int(speed.rounded())) km/h"))
            }
            if let longest = stats.longest {
                row(String(localized: "Längste Fahrt"), "\(FormatUtils.formatDistance(longest.drivenMeters ?? longest.distanceMeters)) · \(longest.destinationName.components(separatedBy: ",").first ?? "")")
            }
            if stats.fuelCost > 0 {
                row(String(localized: "Spritkosten gesamt"), FormatUtils.euro(stats.fuelCost))
            }
            if let fastest = stats.fastest, let max = fastest.maxKmh {
                row(String(localized: "Höchstgeschwindigkeit"), String(localized: "\(Int(max.rounded())) km/h"))
            }
            if !stats.topDestinations.isEmpty {
                row(String(localized: "Häufigste Ziele"), stats.topDestinations.map { String(localized: "\($0.name) (\($0.count)×)") }.joined(separator: ", "))
            }
            if let csvFile {
                ShareLink(item: csvFile) {
                    Label("Als CSV exportieren (Excel, Numbers)", systemImage: "tablecells")
                }
            }
        } header: {
            Text("Statistik")
        }
        .task(id: trips.count) { csvFile = try? TripStats.writeCSV(trips) }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).lineLimit(2)
        }
    }
}

/** Auswertung (ohne UI, per macOS-Test prüfbar). */
struct TripStats {
    enum Period: String, CaseIterable, Identifiable {
        case weeks, months
        var id: String { rawValue }
        var label: String { self == .weeks ? String(localized: "Wochen") : String(localized: "Monate") }
        var component: Calendar.Component { self == .weeks ? .weekOfYear : .month }
        var count: Int { self == .weeks ? 8 : 12 }
    }

    enum Metric: String, CaseIterable, Identifiable {
        case km, trips, cost, speed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .km: return String(localized: "Kilometer")
            case .trips: return String(localized: "Fahrten")
            case .cost: return String(localized: "Kosten")
            case .speed: return String(localized: "Ø Tempo")
            }
        }
        var unitNote: String {
            switch self {
            case .km: return String(localized: "Gefahrene Kilometer")
            case .trips: return String(localized: "Anzahl Fahrten")
            case .cost: return String(localized: "Geschätzte Spritkosten in Euro")
            case .speed: return String(localized: "Durchschnittsgeschwindigkeit in km/h")
            }
        }
    }

    struct Bucket: Identifiable {
        let start: Date
        let km: Double
        let count: Int
        let cost: Double
        let averageKmh: Double
        var id: Date { start }

        func value(_ metric: Metric) -> Double {
            switch metric {
            case .km: return km
            case .trips: return Double(count)
            case .cost: return cost
            case .speed: return averageKmh
            }
        }
    }

    let count: Int
    let totalMeters: Double
    let totalSeconds: Double
    private let trips: [Trip]
    private let now: Date
    private let calendar: Calendar
    let averageMeters: Double
    let averageSeconds: Double
    /** Ø aller Fahrten mit gemessenem Tempo; nil = keine Messung. */
    let averageKmh: Double?
    let longest: Trip?
    let fastest: Trip?
    let topDestinations: [(name: String, count: Int)]
    /** Summe der geschätzten Spritkosten (Euro). */
    let fuelCost: Double

    init(trips: [Trip], now: Date = Date(), calendar: Calendar = .current) {
        count = trips.count
        totalMeters = trips.reduce(0) { $0 + ($1.drivenMeters ?? $1.distanceMeters) }
        totalSeconds = trips.reduce(0) { $0 + $1.durationSeconds }
        fuelCost = trips.reduce(0) { $0 + ($1.fuelCost ?? 0) }
        longest = trips.max { ($0.drivenMeters ?? $0.distanceMeters) < ($1.drivenMeters ?? $1.distanceMeters) }
        fastest = trips.filter { $0.maxKmh != nil }.max { ($0.maxKmh ?? 0) < ($1.maxKmh ?? 0) }

        self.trips = trips
        self.now = now
        var cal = calendar
        cal.firstWeekday = 2 // Montag als Wochenbeginn
        self.calendar = cal
        averageMeters = trips.isEmpty ? 0 : totalMeters / Double(trips.count)
        averageSeconds = trips.isEmpty ? 0 : totalSeconds / Double(trips.count)
        let speeds = trips.compactMap(\.averageKmh)
        averageKmh = speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)

        // Ziele nach dem ersten Teil des Namens zählen („Zuhause“, „Hauptstraße 3“).
        var counts: [String: Int] = [:]
        for trip in trips {
            let name = trip.destinationName.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? trip.destinationName
            counts[name, default: 0] += 1
        }
        topDestinations = counts.filter { $0.value > 1 }.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(3).map { ($0.key, $0.value) }
    }

    /** Die letzten Wochen bzw. Monate (auch leere), älteste zuerst. */
    func buckets(_ period: Period) -> [Bucket] {
        let component = period.component
        guard let current = calendar.dateInterval(of: component, for: now)?.start else { return [] }
        return (0..<period.count).reversed().compactMap { offset -> Bucket? in
            guard let start = calendar.date(byAdding: component, value: -offset, to: current),
                  let end = calendar.date(byAdding: component, value: 1, to: start) else { return nil }
            let inside = trips.filter { $0.timestamp >= start && $0.timestamp < end }
            let meters = inside.reduce(0) { $0 + ($1.drivenMeters ?? $1.distanceMeters) }
            let speeds = inside.compactMap(\.averageKmh)
            return Bucket(start: start, km: meters / 1000, count: inside.count,
                          cost: inside.reduce(0) { $0 + ($1.fuelCost ?? 0) },
                          averageKmh: speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count))
        }
    }

    /** CSV mit Semikolon und Komma-Dezimalen (öffnet in deutschem Excel/Numbers direkt richtig). */
    static func csv(_ trips: [Trip]) -> String {
        let date = DateFormatter()
        date.dateFormat = "dd.MM.yyyy HH:mm"
        func number(_ value: Double?, _ digits: Int = 1) -> String {
            guard let value else { return "" }
            return String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
        }
        func field(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = [String(localized: "Datum;Ziel;Geplant (km);Gefahren (km);Dauer (min);Ø (km/h);Max (km/h)")]
        for trip in trips.sorted(by: { $0.timestamp < $1.timestamp }) {
            lines.append([
                date.string(from: trip.timestamp),
                field(trip.destinationName),
                number(trip.distanceMeters / 1000),
                number(trip.drivenMeters.map { $0 / 1000 }),
                number(trip.durationSeconds / 60, 0),
                number(trip.averageKmh, 0),
                number(trip.maxKmh, 0)
            ].joined(separator: ";"))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /** UTF-8 mit BOM — sonst zeigt Excel Umlaute falsch. */
    static func writeCSV(_ trips: [Trip]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LumoGo_Fahrtenbuch.csv")
        try (Data([0xEF, 0xBB, 0xBF]) + Data(csv(trips).utf8)).write(to: url, options: .atomic)
        return url
    }
}
