import Foundation

/** GPX 1.1 einer aufgezeichneten Fahrt (für Komoot, Strava, Google Earth …). */
enum GPX {
    static func document(name: String, points: [TrackPoint]) -> String {
        let iso = ISO8601DateFormatter()
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="LumoGo" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "  <trk>",
            "    <name>\(escape(name))</name>",
            "    <trkseg>"
        ]
        for p in points {
            lines.append(String(format: #"      <trkpt lat="%.6f" lon="%.6f"><time>%@</time></trkpt>"#,
                                p.lat, p.lon, iso.string(from: Date(timeIntervalSince1970: p.time))))
        }
        lines += ["    </trkseg>", "  </trk>", "</gpx>", ""]
        return lines.joined(separator: "\n")
    }

    /** Schreibt die GPX-Datei in einen temporären Ordner (zum Teilen); Dateiname aus Ziel + Datum. */
    static func writeTemporaryFile(trip: Trip, points: [TrackPoint]) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let safeName = trip.destinationName
            .components(separatedBy: CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "äöüÄÖÜß")))
            .filter { !$0.isEmpty }.prefix(4).joined(separator: "_")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LumoGo_\(formatter.string(from: trip.timestamp))_\(safeName).gpx")
        try document(name: trip.destinationName, points: points).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
