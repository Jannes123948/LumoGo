import Foundation

/**
 * Liest den OSM-Tag `opening_hours` (z.B. `Mo-Fr 08:00-18:00; Sa 09:00-14:00; Su off`) und
 * berechnet daraus „Geöffnet · bis 18:00“ bzw. „Geschlossen · öffnet morgen um 08:00“.
 *
 * Bewusst nur die häufige Teilmenge der Syntax: Wochentage/-bereiche, Zeitspannen (auch über
 * Mitternacht), `off`/`closed`, `24/7`. Spätere Regeln überschreiben frühere für dieselben Tage
 * (wie in der OSM-Spezifikation). Feiertage (`PH`/`SH`) werden ignoriert. Alles andere (Monate,
 * Wochennummern, `sunrise`, …) → [parse] liefert nil, die Oberfläche zeigt dann den Rohtext.
 */
struct OpeningHours {

    /** Minuten ab Tagesbeginn; [end] darf > 1440 sein (Spanne geht über Mitternacht). */
    struct Span: Equatable {
        let start: Int
        let end: Int
    }

    struct Status {
        let isOpen: Bool
        /** Schließt innerhalb der nächsten Stunde (bzw. öffnet innerhalb der nächsten Stunde). */
        let changesSoon: Bool
        let text: String
    }

    /** Index 0 = Montag … 6 = Sonntag. */
    let days: [[Span]]

    static let dayNames = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
    private static let dayTokens: [String: Int] = [
        "mo": 0, "tu": 1, "di": 1, "we": 2, "mi": 2, "th": 3, "do": 3,
        "fr": 4, "sa": 5, "su": 6, "so": 6
    ]

    // MARK: - Parsen

    static func parse(_ raw: String) -> OpeningHours? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("||") else { return nil }
        // Kommentare in Anführungszeichen ("nach Vereinbarung") entfernen.
        text = text.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
        // "Mo-Fr 08:00-12:00, Sa 09:00-12:00": Komma nach einer Uhrzeit vor einem Wochentag
        // trennt eine neue Regel ab (sonst würde "Sa" als Zeitangabe gelesen).
        text = text.replacingOccurrences(
            of: "(?<=\\d)\\s*,\\s*(?=(Mo|Tu|We|Th|Fr|Sa|Su|PH|SH)\\b)",
            with: ";", options: .regularExpression
        )

        var days = [[Span]](repeating: [], count: 7)
        var anyRule = false
        for rawRule in text.split(separator: ";") {
            let rule = rawRule.trimmingCharacters(in: .whitespaces)
            if rule.isEmpty { continue }
            if rule == "24/7" {
                days = [[Span]](repeating: [Span(start: 0, end: 1440)], count: 7)
                anyRule = true
                continue
            }

            // Tagesteil = alles vor der ersten Uhrzeit bzw. vor off/closed.
            let splitRange = rule.range(of: "\\d{1,2}:\\d{2}|\\b(off|closed)\\b", options: [.regularExpression, .caseInsensitive])
            let dayPart = (splitRange.map { String(rule[..<$0.lowerBound]) } ?? rule).trimmingCharacters(in: .whitespaces)
            let timePart = (splitRange.map { String(rule[$0.lowerBound...]) } ?? "").trimmingCharacters(in: .whitespaces)

            guard let selected = parseDays(dayPart) else { return nil }
            if selected.isEmpty { continue } // reine Feiertagsregel
            guard let spans = parseTimes(timePart) else { return nil }
            for day in selected { days[day] = spans }
            anyRule = true
        }
        return anyRule ? OpeningHours(days: days) : nil
    }

    /** Leer = alle Tage; nil = nicht unterstützte Angabe; leere Menge = nur Feiertage. */
    private static func parseDays(_ part: String) -> [Int]? {
        if part.isEmpty { return Array(0..<7) }
        var result: [Int] = []
        for item in part.split(separator: ",") {
            let token = item.trimmingCharacters(in: .whitespaces).lowercased()
            if token == "ph" || token == "sh" { continue }
            let bounds = token.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(bounds.count),
                  let from = dayTokens[bounds[0]],
                  let to = dayTokens[bounds.last!] else { return nil }
            var day = from
            while true {
                result.append(day)
                if day == to { break }
                day = (day + 1) % 7
            }
        }
        return result
    }

    /** Leer = ganztägig; "off"/"closed" = geschlossen; nil = nicht unterstützt. */
    private static func parseTimes(_ part: String) -> [Span]? {
        if part.isEmpty { return [Span(start: 0, end: 1440)] }
        let lower = part.lowercased()
        if lower == "off" || lower == "closed" { return [] }
        var spans: [Span] = []
        for item in part.split(separator: ",") {
            let piece = item.trimmingCharacters(in: .whitespaces)
            let pattern = "^(\\d{1,2}):(\\d{2})\\s*-\\s*(\\d{1,2}):(\\d{2})$"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: piece, range: NSRange(piece.startIndex..., in: piece)) else {
                // "18:00+" (offenes Ende) → bis Mitternacht
                if piece.hasSuffix("+"), let start = minutes(String(piece.dropLast())) {
                    spans.append(Span(start: start, end: 1440))
                    continue
                }
                return nil
            }
            func group(_ i: Int) -> Int { Int(piece[Range(match.range(at: i), in: piece)!])! }
            let start = group(1) * 60 + group(2)
            var end = group(3) * 60 + group(4)
            guard start <= 1440, end <= 48 * 60 else { return nil }
            if end <= start { end += 1440 }
            spans.append(Span(start: start, end: end))
        }
        return spans.sorted { $0.start < $1.start }
    }

    private static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }

    // MARK: - Auswertung

    /** Wochentag-Index (0 = Montag) eines Datums. */
    static func dayIndex(_ date: Date, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7
    }

    var isAlwaysOpen: Bool {
        days.allSatisfy { spans in spans.contains { $0.start == 0 && $0.end >= 1440 } }
    }

    func status(at date: Date = Date(), calendar: Calendar = .current) -> Status {
        if isAlwaysOpen { return Status(isOpen: true, changesSoon: false, text: "Rund um die Uhr geöffnet") }
        let today = Self.dayIndex(date, calendar: calendar)
        let now = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)

        // Alle Spannen als absolute Minuten ab heute 00:00 (gestern bis +7 Tage), zusammengefügt.
        var timeline: [Span] = []
        for offset in -1...7 {
            for span in days[((today + offset) % 7 + 7) % 7] {
                timeline.append(Span(start: span.start + offset * 1440, end: span.end + offset * 1440))
            }
        }
        timeline.sort { $0.start < $1.start }
        var merged: [Span] = []
        for span in timeline {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = Span(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }

        if let current = merged.first(where: { $0.start <= now && now < $0.end }) {
            let soon = current.end - now <= 60
            return Status(isOpen: true, changesSoon: soon,
                          text: (soon ? "Schließt bald · " : "Geöffnet · bis ") + Self.describe(current.end, now: now, today: today))
        }
        if let next = merged.first(where: { $0.start > now }) {
            let soon = next.start - now <= 60
            return Status(isOpen: false, changesSoon: soon,
                          text: "Geschlossen · öffnet " + Self.describe(next.start, now: now, today: today, withUm: true))
        }
        return Status(isOpen: false, changesSoon: false, text: "Geschlossen")
    }

    /** "22:00" (heute), "morgen um 08:00", "Mo um 08:00". */
    private static func describe(_ absolute: Int, now: Int, today: Int, withUm: Bool = false) -> String {
        let dayOffset = absolute / 1440
        let time = clock(absolute % 1440)
        // Schließen genau um Mitternacht: "bis 24:00" statt "bis morgen um 00:00".
        if absolute == 1440 && !withUm { return "24:00" }
        switch dayOffset {
        case 0: return withUm ? "um \(time)" : time
        case 1: return "morgen um \(time)"
        default: return "\(dayNames[(today + dayOffset) % 7]) um \(time)"
        }
    }

    static func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /** Wochenübersicht für die Detailansicht: ("Mo", "08:00–12:00, 14:00–18:00"). */
    var weeklyLines: [(day: String, hours: String)] {
        days.enumerated().map { index, spans in
            let text: String
            if spans.isEmpty {
                text = "Geschlossen"
            } else if spans.contains(where: { $0.start == 0 && $0.end >= 1440 }) {
                text = "24 Stunden"
            } else {
                text = spans.map { span in
                    let end = span.end == 1440 ? "24:00" : Self.clock(span.end % 1440)
                    return "\(Self.clock(span.start))–\(end)"
                }.joined(separator: ", ")
            }
            return (Self.dayNames[index], text)
        }
    }
}
