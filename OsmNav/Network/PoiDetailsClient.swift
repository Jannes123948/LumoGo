import Foundation

/** Infos zu einem angetippten Ort (aus den OSM-Tags), angezeigt im Detail-Blatt. */
struct PoiDetails {
    let name: String
    let point: LatLon
    let category: String?
    let address: String?
    let openingHoursRaw: String?
    let phone: String?
    let website: URL?

    var openingHours: OpeningHours? { openingHoursRaw.flatMap(OpeningHours.parse) }

    init(name: String, point: LatLon, tags: [String: String]) {
        func tag(_ key: String) -> String? {
            guard let v = tags[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        self.name = name
        self.point = point
        category = PoiCategoryNames.label(tags)
        let street = tag("addr:street").map { s in tag("addr:housenumber").map { "\(s) \($0)" } ?? s }
        let city = tag("addr:city") ?? tag("addr:town") ?? tag("addr:village") ?? tag("addr:suburb")
        let place = [tag("addr:postcode"), city].compactMap { $0 }.joined(separator: " ")
        let joined = [street, place.isEmpty ? nil : place].compactMap { $0 }.joined(separator: ", ")
        address = joined.isEmpty ? nil : joined
        openingHoursRaw = tag("opening_hours")
        // Mehrere Nummern sind per ";" getrennt — die erste reicht zum Anrufen.
        phone = (tag("phone") ?? tag("contact:phone"))?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        website = (tag("website") ?? tag("contact:website") ?? tag("url")).flatMap { raw in
            URL(string: raw.hasPrefix("http") ? raw : "https://\(raw)")
        }
    }
}

/**
 * Lädt die OSM-Tags eines angetippten Orts per Overpass: entweder per Name rund um die
 * Antippstelle (Vektorkarte liefert den Namen des POI-Symbols mit) oder — Rasterkarte/dunkler
 * Stil ohne POI-Symbole — den nächstgelegenen benannten Ort im Umkreis.
 */
enum PoiDetailsClient {

    private static let timeoutSeconds = 20.0
    private static let poiKeys = "amenity|shop|tourism|leisure|healthcare|office|craft|historic|railway|public_transport|aeroway"

    /** Sucht den Ort mit genau diesem Namen nahe [near]; nil, wenn Overpass nichts findet. */
    static func fetch(name: String, near: LatLon) async throws -> PoiDetails? {
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let around = "around:80,\(near.latitude),\(near.longitude)"
        return try await query("nwr[\"name\"=\"\(escaped)\"](\(around));", near: near)
    }

    /** Nächster benannter POI im Umkreis von [radiusMeters] um [near]. */
    static func fetchNearest(_ near: LatLon, radiusMeters: Int) async throws -> PoiDetails? {
        let around = "around:\(radiusMeters),\(near.latitude),\(near.longitude)"
        return try await query("nwr[\"name\"][~\"^(\(poiKeys))$\"~\".\"](\(around));", near: near)
    }

    private static func query(_ statement: String, near: LatLon) async throws -> PoiDetails? {
        let q = "[out:json][timeout:12];\n\(statement)\nout tags center 20;"
        let result: Result<Data, Error>? = await withTimeout(seconds: timeoutSeconds) {
            do { return .success(try await OverpassClient.rawQuery(q, retryCount: 2)) } catch { return .failure(error) }
        }
        guard let result else { throw AppError.server("Zeitüberschreitung") }
        let data = try result.get()

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { throw AppError.parse }
        let candidates: [PoiDetails] = elements.compactMap { el in
            guard let tags = el["tags"] as? [String: String], let name = tags["name"] else { return nil }
            let lat = (el["lat"] as? Double) ?? ((el["center"] as? [String: Any])?["lat"] as? Double)
            let lon = (el["lon"] as? Double) ?? ((el["center"] as? [String: Any])?["lon"] as? Double)
            guard let lat, let lon else { return nil }
            return PoiDetails(name: name, point: LatLon(lat, lon), tags: tags)
        }
        // Nächster Treffer; bei Gleichstand der mit mehr Infos (Gebäude-Umriss vs. Eingangs-Knoten).
        return candidates.min { a, b in
            let da = GeoUtils.distanceMeters(near, a.point) - (a.openingHoursRaw != nil ? 15 : 0)
            let db = GeoUtils.distanceMeters(near, b.point) - (b.openingHoursRaw != nil ? 15 : 0)
            return da < db
        }
    }
}

/** Deutsche Bezeichnungen für häufige OSM-Kategorien; sonst der Rohwert lesbar gemacht. */
enum PoiCategoryNames {

    private static let names: [String: String] = [
        "restaurant": "Restaurant", "fast_food": "Fast Food", "cafe": "Café", "bar": "Bar", "pub": "Kneipe",
        "biergarten": "Biergarten", "ice_cream": "Eisdiele", "fuel": "Tankstelle", "parking": "Parkplatz",
        "charging_station": "Ladesäule", "pharmacy": "Apotheke", "hospital": "Krankenhaus", "doctors": "Arztpraxis",
        "dentist": "Zahnarzt", "bank": "Bank", "atm": "Geldautomat", "post_office": "Post", "school": "Schule",
        "kindergarten": "Kindergarten", "university": "Universität", "library": "Bibliothek", "police": "Polizei",
        "townhall": "Rathaus", "theatre": "Theater", "cinema": "Kino", "place_of_worship": "Gotteshaus",
        "toilets": "Toiletten", "car_wash": "Autowäsche", "car_rental": "Autovermietung", "fire_station": "Feuerwehr",
        "supermarket": "Supermarkt", "bakery": "Bäckerei", "butcher": "Metzgerei", "convenience": "Lebensmittel",
        "kiosk": "Kiosk", "clothes": "Bekleidung", "shoes": "Schuhe", "hairdresser": "Friseur", "chemist": "Drogerie",
        "doityourself": "Baumarkt", "hardware": "Eisenwaren", "electronics": "Elektronik", "furniture": "Möbel",
        "car": "Autohaus", "car_repair": "Autowerkstatt", "bicycle": "Fahrradladen", "florist": "Blumen",
        "optician": "Optiker", "beverages": "Getränkemarkt", "department_store": "Kaufhaus", "mall": "Einkaufszentrum",
        "books": "Buchhandlung", "gift": "Geschenke", "jewelry": "Schmuck", "mobile_phone": "Handyladen",
        "hotel": "Hotel", "guest_house": "Pension", "hostel": "Hostel", "camp_site": "Campingplatz",
        "museum": "Museum", "attraction": "Sehenswürdigkeit", "viewpoint": "Aussichtspunkt",
        "information": "Touristeninformation", "zoo": "Zoo", "theme_park": "Freizeitpark",
        "park": "Park", "playground": "Spielplatz", "sports_centre": "Sportzentrum", "swimming_pool": "Schwimmbad",
        "fitness_centre": "Fitnessstudio", "pitch": "Sportplatz", "stadium": "Stadion",
        "station": "Bahnhof", "halt": "Haltepunkt", "tram_stop": "Straßenbahnhaltestelle",
        "castle": "Burg/Schloss", "monument": "Denkmal", "memorial": "Gedenkstätte", "ruins": "Ruine",
        "aerodrome": "Flugplatz"
    ]

    static func label(_ tags: [String: String]) -> String? {
        if tags["amenity"] == "place_of_worship" {
            switch tags["religion"] {
            case "christian": return "Kirche"
            case "muslim": return "Moschee"
            case "jewish": return "Synagoge"
            default: break
            }
        }
        for key in ["amenity", "shop", "tourism", "leisure", "healthcare", "office", "craft", "historic", "railway", "aeroway"] {
            guard let value = tags[key], value != "yes" else { continue }
            if let name = names[value] { return name }
            let readable = value.replacingOccurrences(of: "_", with: " ")
            return readable.prefix(1).uppercased() + readable.dropFirst()
        }
        return nil
    }
}
