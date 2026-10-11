import Foundation

/**
 * Liest Orte aus geteilten Links/Texten: Apple Karten, Google Maps, OpenStreetMap, `geo:`-Links,
 * Koordinaten im Text und (ohne Koordinaten) Adressen/Namen als Suchtext. Kurzlinks
 * (maps.app.goo.gl, maps.apple/p/…) löst [resolve] vorher über die Weiterleitung auf.
 */
enum SharedLinkParser {

    /** Ort aus Links + Texten; Koordinaten haben Vorrang, der Name kommt notfalls aus dem Text. */
    static func place(urls: [URL], texts: [String]) -> SharedPlace? {
        // Links, die im Text stehen (WhatsApp, Notizen), mitnehmen.
        let textURLs = texts.flatMap(urlsInText)
        var best: SharedPlace?
        for url in urls + textURLs {
            guard let found = parse(url) else { continue }
            if found.hasCoordinate { best = found; break }
            if best == nil { best = found }
        }
        let cleanedTexts = texts.map(removingURLs).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if best?.hasCoordinate != true, let coordinate = cleanedTexts.lazy.compactMap(coordinateInText).first {
            best = SharedPlace(latitude: coordinate.0, longitude: coordinate.1, name: best?.name ?? best?.query)
        }
        if var place = best {
            if isGenericName(place.name) { place.name = nil }
            // Name aus dem Text (Apple Karten teilt „Name\nAdresse\nLink“).
            if place.name == nil, place.hasCoordinate { place.name = cleanedTexts.first.flatMap(titleFromText) }
            return place
        }
        guard let query = cleanedTexts.first.flatMap(nameFromText) else { return nil }
        return SharedPlace(query: query)
    }

    /** Ort aus einem einzelnen Link; nil = kein Karten-Link. */
    static func parse(_ url: URL) -> SharedPlace? {
        if url.scheme?.lowercased() == "geo" { return parseGeo(url.absoluteString) }
        guard let host = url.host?.lowercased() else { return nil }
        let items = queryItems(url)
        func q(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }

        // Google leitet in der EU erst auf die Einwilligungsseite — das Ziel steht in `continue`.
        if host.hasPrefix("consent."), let target = q("continue").flatMap(URL.init(string:)) {
            return parse(target)
        }

        if host.contains("apple.com") || host == "maps.apple" {
            let name = q("q") ?? q("name") ?? q("address")
            for key in ["coordinate", "ll", "daddr", "sll", "q"] {
                if let value = q(key), let c = coordinate(in: value) {
                    return SharedPlace(latitude: c.0, longitude: c.1, name: key == "q" ? nil : name)
                }
            }
            if let address = q("address") ?? q("daddr") ?? q("q") { return SharedPlace(name: nil, query: address) }
            return nil
        }

        if host.contains("google.") || host.hasPrefix("goo.gl") || host.contains("maps.app.goo.gl") {
            let path = url.path.removingPercentEncoding ?? url.path
            let placeName = placeNameFromGooglePath(path)
            // Genaue Lage des Orts: …!3d51.05!4d13.73 (das @… davor ist nur der Kartenausschnitt).
            let full = url.absoluteString.removingPercentEncoding ?? url.absoluteString
            if let c = googleDataCoordinate(full) {
                return SharedPlace(latitude: c.0, longitude: c.1, name: placeName)
            }
            for key in ["q", "query", "destination", "daddr", "ll", "center"] {
                if let value = q(key), let c = coordinate(in: value) {
                    return SharedPlace(latitude: c.0, longitude: c.1, name: placeName)
                }
            }
            if let c = atCoordinate(path) {
                return SharedPlace(latitude: c.0, longitude: c.1, name: placeName)
            }
            if let text = q("q") ?? q("query") ?? q("destination") ?? q("daddr") ?? placeName {
                return SharedPlace(query: text)
            }
            return nil
        }

        if host.contains("openstreetmap.org") || host == "osm.org" {
            if let lat = q("mlat").flatMap(Double.init), let lon = q("mlon").flatMap(Double.init), valid(lat, lon) {
                return SharedPlace(latitude: lat, longitude: lon)
            }
            if let fragment = url.fragment, let range = fragment.range(of: "map=") {
                let parts = fragment[range.upperBound...].split(separator: "/")
                if parts.count >= 3, let lat = Double(parts[1]), let lon = Double(parts[2].prefix { $0 != "&" }), valid(lat, lon) {
                    return SharedPlace(latitude: lat, longitude: lon)
                }
            }
            return nil
        }
        return nil
    }

    /** Muss der Link erst aufgelöst werden (Kurzlink ohne Ort darin)? */
    static func needsResolving(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "maps.app.goo.gl" || host == "goo.gl" || host == "maps.apple" || host == "g.co"
            || (host.hasSuffix("apple.com") && url.path.hasPrefix("/p/"))
    }

    /** Kurzlink → Ziel-URL (folgt den Weiterleitungen). */
    static func resolve(_ url: URL) async -> URL {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request), let final = response.url else { return url }
        return final
    }

    // MARK: - Einzelteile

    private static func parseGeo(_ string: String) -> SharedPlace? {
        // geo:51.05,13.73?q=…  bzw. geo:0,0?q=51.05,13.73(Name)  bzw. geo:0,0?q=Adresse
        let body = string.dropFirst(4)
        let parts = body.split(separator: "?", maxSplits: 1)
        let query = parts.count > 1 ? parts[1].split(separator: "&").first { $0.hasPrefix("q=") }.map { String($0.dropFirst(2)) } : nil
        let decoded = query.flatMap { $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
        if let decoded, let c = coordinate(in: decoded) {
            let name = decoded.range(of: "(").map { String(decoded[$0.upperBound...].prefix { $0 != ")" }) }
            return SharedPlace(latitude: c.0, longitude: c.1, name: name?.isEmpty == false ? name : nil)
        }
        if let first = parts.first, let c = coordinate(in: String(first)), !(c.0 == 0 && c.1 == 0) {
            return SharedPlace(latitude: c.0, longitude: c.1)
        }
        if let decoded, !decoded.isEmpty { return SharedPlace(query: decoded) }
        return nil
    }

    private static func queryItems(_ url: URL) -> [URLQueryItem] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // „+“ steht in Karten-Links für Leerzeichen.
        return items.map { URLQueryItem(name: $0.name, value: $0.value?.replacingOccurrences(of: "+", with: " ")) }
    }

    /** „/maps/place/Frauenkirche+Dresden/@…“ → „Frauenkirche Dresden“. */
    private static func placeNameFromGooglePath(_ path: String) -> String? {
        guard let range = path.range(of: "/place/") else { return nil }
        let raw = path[range.upperBound...].prefix { $0 != "/" }
        let name = raw.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty || coordinate(in: name) != nil { return nil }
        return name
    }

    private static func googleDataCoordinate(_ s: String) -> (Double, Double)? {
        guard let m = s.range(of: #"!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)"#, options: .regularExpression) else { return nil }
        let numbers = s[m].split(separator: "!").compactMap { part -> Double? in Double(part.dropFirst(2)) }
        guard numbers.count == 2, valid(numbers[0], numbers[1]) else { return nil }
        return (numbers[0], numbers[1])
    }

    private static func atCoordinate(_ s: String) -> (Double, Double)? {
        guard let m = s.range(of: #"@-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?"#, options: .regularExpression) else { return nil }
        return coordinate(in: String(s[m].dropFirst()))
    }

    /** „51.0504,13.7373“ / „51.0504, 13.7373“ irgendwo im Wert. */
    static func coordinate(in s: String) -> (Double, Double)? {
        guard let m = s.range(of: #"-?\d{1,2}\.\d+\s*,\s*-?\d{1,3}\.\d+"#, options: .regularExpression) else { return nil }
        let parts = s[m].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]), valid(lat, lon) else { return nil }
        return (lat, lon)
    }

    /** Koordinaten im Freitext, auch „51,0504° N, 13,7373° O“. */
    static func coordinateInText(_ text: String) -> (Double, Double)? {
        if let c = coordinate(in: text) { return c }
        let pattern = #"(\d{1,2})[.,](\d+)\s*°?\s*([NS])\s*[,;]?\s*(\d{1,3})[.,](\d+)\s*°?\s*([EOW])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ i: Int) -> String { Range(match.range(at: i), in: text).map { String(text[$0]) } ?? "" }
        guard var lat = Double("\(group(1)).\(group(2))"), var lon = Double("\(group(4)).\(group(5))") else { return nil }
        if group(3).uppercased() == "S" { lat = -lat }
        if group(6).uppercased() == "W" { lon = -lon }
        return valid(lat, lon) ? (lat, lon) : nil
    }

    private static func valid(_ lat: Double, _ lon: Double) -> Bool {
        abs(lat) <= 90 && abs(lon) <= 180 && !(lat == 0 && lon == 0)
    }

    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func urlsInText(_ text: String) -> [URL] {
        let range = NSRange(text.startIndex..., in: text)
        var result = linkDetector?.matches(in: text, range: range).compactMap(\.url) ?? []
        // geo:-Links erkennt der Detektor nicht.
        if let r = text.range(of: #"geo:[^\s]+"#, options: .regularExpression), let url = URL(string: String(text[r])) {
            result.append(url)
        }
        return result
    }

    private static func removingURLs(_ text: String) -> String {
        var result = text
        let range = NSRange(text.startIndex..., in: text)
        for match in (linkDetector?.matches(in: text, range: range) ?? []).reversed() {
            if let r = Range(match.range, in: result) { result.removeSubrange(r) }
        }
        return result
    }

    /** Platzhalter-Namen von Karten-Apps für gesetzte Stecknadeln. */
    private static func isGenericName(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return ["markierter ort", "markierte stelle", "marked location", "dropped pin", "standort", "mein standort",
                "current location", "aktueller ort", "aktueller standort"].contains(n)
    }

    /** Erste Zeile als Name, wenn sie wie ein Name aussieht (kurz, keine Koordinaten, kein „Standort:“). */
    private static func titleFromText(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
              !line.isEmpty, line.count <= 60, !line.hasSuffix(":"), coordinateInText(line) == nil,
              !isGenericName(line) else { return nil }
        return line
    }

    /** Erste sinnvolle Zeile als Name/Suchtext (ohne „Teilen“-Floskeln, höchstens 200 Zeichen). */
    private static func nameFromText(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        // „Name\nStraße 1, 01067 Dresden“ → beides zusammen findet die Suche am besten.
        let joined = lines.prefix(2).joined(separator: ", ")
        return String(joined.prefix(200))
    }
}
