import SwiftUI
import Charts

/** Kennzahlen des Fahrtenbuchs: Summen, km je Woche, Rekorde, häufige Ziele, CSV-Export. */
struct TripStatsSection: View {
    let trips: [Trip]
    @State private var csvFile: URL?

    var body: some View {
        let stats = TripStats(trips: trips)
        Section {
            HStack(spacing: 0) {
                statTile(String(localized: "\(stats.count)"), String(localized: "Fahrten"))
                statTile(FormatUtils.formatDistance(stats.totalMeters), "gesamt")
                statTile(FormatUtils.formatDuration(stats.totalSeconds), "unterwegs")
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 6) {
                Text("Kilometer je Woche").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Chart(stats.weeks) { week in
                    BarMark(x: .value("Woche", week.start, unit: .weekOfYear), y: .value("km", week.km))
                        .foregroundStyle(Color.accentColor.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .weekOfYear)) { _ in
                        AxisValueLabel(format: .dateTime.day().month(.defaultDigits), centered: true)
                    }
                }
                .frame(height: 120)
            }
            .padding(.vertical, 4)

            if let longest = stats.longest {
                row(String(localized: "Längste Fahrt"), "\(FormatUtils.formatDistance(longest.drivenMeters ?? longest.distanceMeters)) · \(longest.destinationName.components(separatedBy: ",").first ?? "")")
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
    struct Week: Identifiable {
        let start: Date
        let km: Double
        var id: Date { start }
    }

    let count: Int
    let totalMeters: Double
    let totalSeconds: Double
    let weeks: [Week]
    let longest: Trip?
    let fastest: Trip?
    let topDestinations: [(name: String, count: Int)]

    init(trips: [Trip], now: Date = Date(), calendar: Calendar = .current) {
        count = trips.count
        totalMeters = trips.reduce(0) { $0 + ($1.drivenMeters ?? $1.distanceMeters) }
        totalSeconds = trips.reduce(0) { $0 + $1.durationSeconds }
        longest = trips.max { ($0.drivenMeters ?? $0.distanceMeters) < ($1.drivenMeters ?? $1.distanceMeters) }
        fastest = trips.filter { $0.maxKmh != nil }.max { ($0.maxKmh ?? 0) < ($1.maxKmh ?? 0) }

        // Letzte 8 Wochen (auch leere), Montag als Wochenbeginn wie in Deutschland üblich.
        var cal = calendar
        cal.firstWeekday = 2
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        weeks = (0..<8).reversed().compactMap { offset -> Week? in
            guard let start = cal.date(byAdding: .weekOfYear, value: -offset, to: thisWeek),
                  let end = cal.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let meters = trips.filter { $0.timestamp >= start && $0.timestamp < end }
                .reduce(0) { $0 + ($1.drivenMeters ?? $1.distanceMeters) }
            return Week(start: start, km: meters / 1000)
        }

        // Ziele nach dem ersten Teil des Namens zählen („Zuhause“, „Hauptstraße 3“).
        var counts: [String: Int] = [:]
        for trip in trips {
            let name = trip.destinationName.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? trip.destinationName
            counts[name, default: 0] += 1
        }
        topDestinations = counts.filter { $0.value > 1 }.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(3).map { ($0.key, $0.value) }
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
