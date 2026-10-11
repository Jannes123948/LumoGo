import Foundation
import MapLibre

/** Metadaten eines Offline-Kartenpakets — liegen als `context` direkt im MapLibre-Paket. */
struct OfflinePackContext: Codable {
    let id: String
    let name: String
    let boundingBox: BoundingBox
    let minZoom: Int
    let maxZoom: Int
    let createdAt: Date
}

/** Anzeige-Zustand eines Pakets für die Liste. */
struct OfflinePackInfo: Identifiable {
    let id: String
    let context: OfflinePackContext
    let completed: UInt64
    let expected: UInt64
    let bytes: UInt64
    let isComplete: Bool
    let isActive: Bool
    let placesCount: Int
    let hasRouting: Bool

    var fraction: Double { expected > 0 ? Double(completed) / Double(expected) : 0 }
}

/** Slippy-Map-Kachelmathematik für die Größenschätzung vor dem Download. */
enum TileMath {
    static func tileCount(_ bbox: BoundingBox, minZoom: Int, maxZoom: Int) -> Int {
        guard minZoom <= maxZoom else { return 0 }
        return (minZoom...maxZoom).reduce(0) { total, z in
            let n = pow(2.0, Double(z))
            func x(_ lon: Double) -> Int { Int(floor((lon + 180) / 360 * n)).clamped(0, Int(n) - 1) }
            func y(_ lat: Double) -> Int {
                let rad = min(max(lat, -85.0511), 85.0511) * .pi / 180
                return Int(floor((1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2 * n)).clamped(0, Int(n) - 1)
            }
            let xs = x(bbox.east) - x(bbox.west) + 1
            let ys = y(bbox.south) - y(bbox.north) + 1
            return total + max(xs, 0) * max(ys, 0)
        }
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

/**
 * Offline-Kartenpakete über MapLibres `MLNOfflineStorage` (Port von `OfflineMapsActivity`/
 * `MapLibreOfflineDownloader`/`OfflineDownloadService`). Nach dem Kachel-Download werden die
 * Suchdaten (benannte Orte, Overpass) und das Straßennetz (Vektorkacheln bzw. Overpass) geholt,
 * damit Suche UND Routing auch offline funktionieren.
 *
 * Hinweis iOS: MapLibre lädt nur weiter, solange die App aktiv ist (kein Foreground-Service wie
 * auf Android) — wird die App verlassen, pausiert der Download und läuft beim Zurückkehren weiter.
 */
@MainActor
final class OfflineMapsManager: ObservableObject {
    static let shared = OfflineMapsManager()

    @Published private(set) var packs: [OfflinePackInfo] = []
    @Published var lastMessage: String?
    /** Fortschritt des Straßennetz-Downloads je Paket (z.B. "3/9"), nil = läuft nicht. */
    @Published private(set) var routingProgress: [String: String] = [:]
    /** Anteil 0…1 der laufenden Straßennetz- bzw. Suchdaten-Downloads je Paket. */
    @Published private(set) var routingFraction: [String: Double] = [:]
    @Published private(set) var searchFraction: [String: Double] = [:]

    /**
     * Gesamtfortschritt aller laufenden Downloads (Kartenpakete, Suchdaten, Straßennetz) als
     * Mittelwert 0…1 — für die Prozentanzeige links neben der Suchleiste; nil = nichts lädt.
     */
    var activeDownloadFraction: Double? {
        var fractions = packs.filter { $0.isActive && !$0.isComplete }.map(\.fraction)
        fractions += Array(searchFraction.values) + Array(routingFraction.values)
        guard !fractions.isEmpty else { return nil }
        return min(max(fractions.reduce(0, +) / Double(fractions.count), 0), 1)
    }

    /** Was gerade lädt (Text unter der Prozentanzeige / Bedienungshilfe). */
    var activeDownloadLabel: String {
        if packs.contains(where: { $0.isActive && !$0.isComplete }) { return String(localized: "Karte") }
        if !searchFraction.isEmpty { return String(localized: "Suche") }
        return String(localized: "Routing")
    }

    /** Ein ganzes Bundesland bei hohem Zoom überfordert den kostenlosen Kachelserver irgendwann
     *  ohne Fehlermeldung — der Watchdog bricht nach 120s ohne Fortschritt sauber ab. */
    private static let stallTimeout: TimeInterval = 120

    private var observers: [NSObjectProtocol] = []
    private var packsObservation: NSKeyValueObservation?
    private var lastProgressAt: [String: (UInt64, Date)] = [:]
    private var watchdog: Timer?
    private var fetchingPlaces: Set<String> = []
    private var fetchingRouting: Set<String> = []

    private init() {
        let storage = MLNOfflineStorage.shared
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .MLNOfflinePackProgressChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in self?.handleProgress(note.object as? MLNOfflinePack) }
        })
        observers.append(center.addObserver(forName: .MLNOfflinePackError, object: nil, queue: .main) { [weak self] note in
            let error = note.userInfo?[MLNOfflinePackUserInfoKey.error] as? NSError
            Task { @MainActor in self?.lastMessage = String(localized: "Download-Fehler: \(error?.localizedDescription ?? String(localized: "unbekannt"))") }
        })
        packsObservation = storage.observe(\.packs, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                MLNOfflineStorage.shared.packs?.forEach { $0.requestProgress() }
                self?.refresh()
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkStalls() }
        }
    }

    static func context(of pack: MLNOfflinePack) -> OfflinePackContext? {
        try? JSONDecoder().decode(OfflinePackContext.self, from: pack.context)
    }

    var allContexts: [OfflinePackContext] { packs.map(\.context) }

    func refresh() {
        packs = (MLNOfflineStorage.shared.packs ?? []).compactMap { pack in
            guard let ctx = Self.context(of: pack) else { return nil }
            let p = pack.progress
            return OfflinePackInfo(
                id: ctx.id,
                context: ctx,
                completed: p.countOfResourcesCompleted,
                expected: p.countOfResourcesExpected,
                bytes: p.countOfBytesCompleted,
                isComplete: pack.state == .complete,
                isActive: pack.state == .active,
                placesCount: OfflinePlacesStore.shared.count(regionId: ctx.id),
                hasRouting: RoadDataStore.has(ctx.id)
            )
        }.sorted { $0.context.createdAt > $1.context.createdAt }
        // Laufende Paket-Downloads dürfen trotz Offline-Modus ins Netz.
        NetworkPolicy.setPackDownloadsActive(packs.contains { $0.isActive && !$0.isComplete })
    }

    /**
     * Durchschnittliche Bytes je Kachel aus den fertigen Paketen (für die Größenschätzung vor dem
     * Download); ohne Erfahrungswerte grob 15 KB (OpenFreeMap-Vektorkacheln).
     */
    var averageBytesPerTile: Double {
        let done = packs.filter { $0.isComplete && $0.completed > 50 }
        let tiles = done.reduce(0) { $0 + Double($1.completed) }
        let bytes = done.reduce(0) { $0 + Double($1.bytes) }
        return tiles > 0 ? bytes / tiles : 15_000
    }

    func download(name: String, bbox: BoundingBox, minZoom: Int, maxZoom: Int, styleURL: URL) {
        let ctx = OfflinePackContext(id: UUID().uuidString, name: name, boundingBox: bbox, minZoom: minZoom, maxZoom: maxZoom, createdAt: Date())
        let bounds = MLNCoordinateBounds(
            sw: CLLocationCoordinate2D(latitude: bbox.south, longitude: bbox.west),
            ne: CLLocationCoordinate2D(latitude: bbox.north, longitude: bbox.east)
        )
        let region = MLNTilePyramidOfflineRegion(styleURL: styleURL, bounds: bounds, fromZoomLevel: Double(minZoom), toZoomLevel: Double(maxZoom))
        guard let data = try? JSONEncoder().encode(ctx) else { return }
        NetworkPolicy.setPackDownloadsActive(true)
        MLNOfflineStorage.shared.addPack(for: region, withContext: data) { [weak self] pack, error in
            Task { @MainActor in
                if let error {
                    self?.lastMessage = String(localized: "Download konnte nicht gestartet werden: \(error.localizedDescription)")
                    return
                }
                pack?.resume()
                self?.lastProgressAt[ctx.id] = (0, Date())
                self?.refresh()
            }
        }
    }

    func delete(_ info: OfflinePackInfo) {
        guard let pack = findPack(info.id) else { return }
        OfflinePlacesStore.shared.delete(regionId: info.id)
        RoadDataStore.delete(info.id)
        Task { await OfflineRouter.shared.invalidate() }
        MLNOfflineStorage.shared.removePack(pack) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func resume(_ info: OfflinePackInfo) {
        findPack(info.id)?.resume()
        lastProgressAt[info.id] = (info.completed, Date())
    }

    func pause(_ info: OfflinePackInfo) {
        findPack(info.id)?.suspend()
        lastProgressAt[info.id] = nil
    }

    /**
     * Suchdaten für ein Paket (neu) holen — aus der eingestellten Quelle: Kartenkacheln (Standard,
     * MIT Adressen und Straßen, siehe [TilePlacesBuilder]) oder Overpass (nur benannte Orte, dafür mit
     * Öffnungszeiten); scheitert sie, automatisch die andere. [fresh] = Kacheln neu vom Server statt
     * aus dem Kartenpaket (⋯-Menü „aktualisieren“ — das Paket hält den Stand seines Downloads).
     */
    func refreshSearchData(_ ctx: OfflinePackContext, fresh: Bool = false) {
        guard !fetchingPlaces.contains(ctx.id) else { return }
        fetchingPlaces.insert(ctx.id)
        searchFraction[ctx.id] = 0
        let source = OfflineRoadSource.current
        let databasePath = MLNOfflineStorage.shared.databasePath
        NetworkPolicy.beginDataDownload()
        Task {
            defer { NetworkPolicy.endDataDownload() }
            do {
                let places = try await Self.fetchSearchData(ctx.boundingBox, source: source, databasePath: databasePath, fresh: fresh) { fraction in
                    Task { @MainActor in if self.searchFraction[ctx.id] != nil { self.searchFraction[ctx.id] = fraction } }
                }
                OfflinePlacesStore.shared.replace(regionId: ctx.id, places: places)
                lastMessage = String(localized: "Offline-Suche für „\(ctx.name)“: \(places.count.formatted()) Orte und Adressen gespeichert.")
            } catch {
                lastMessage = String(localized: "Suchdaten für „\(ctx.name)“ konnten nicht geladen werden (Kachel- und Overpass-Server nicht erreichbar?).")
            }
            fetchingPlaces.remove(ctx.id)
            searchFraction[ctx.id] = nil
            refresh()
        }
    }

    private nonisolated static func fetchSearchData(_ bbox: BoundingBox, source: OfflineRoadSource, databasePath: String?, fresh: Bool,
                                                    progress: @escaping (Double) -> Void) async throws -> [OverpassPlace] {
        let order: [OfflineRoadSource] = source == .tiles ? [.tiles, .overpass] : [.overpass, .tiles]
        var lastError: Error = AppError.noResults
        for candidate in order {
            try Task.checkCancellation()
            do {
                switch candidate {
                case .tiles: return try await TilePlacesBuilder.download(bbox, databasePath: databasePath, preferNetwork: fresh, progress: progress)
                case .overpass: return try await fetchPlacesInChunks(bbox, progress: progress)
                }
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /**
     * Straßennetz fürs Offline-Routing laden — aus der eingestellten Quelle (Standard: Vektorkacheln,
     * siehe [TileRoadBuilder]), scheitert sie, automatisch aus der anderen (Overpass). [fresh] wie bei
     * [refreshSearchData].
     */
    func refreshRoutingData(_ ctx: OfflinePackContext, fresh: Bool = false) {
        guard !fetchingRouting.contains(ctx.id) else { return }
        fetchingRouting.insert(ctx.id)
        routingProgress[ctx.id] = String(localized: "startet …")
        routingFraction[ctx.id] = 0
        // Läuft parallel zum Suchdaten-Download (Server erlaubt 4 Anfragen je Client) — früher
        // wartete das Straßennetz, bis die Suchdaten fertig waren.
        let includePaths = UserDefaults.standard.object(forKey: "offline_paths") as? Bool ?? false
        let source = OfflineRoadSource.current
        let databasePath = MLNOfflineStorage.shared.databasePath
        NetworkPolicy.beginDataDownload()
        Task {
            defer { NetworkPolicy.endDataDownload() }
            do {
                let (parts, used) = try await Self.buildRoadData(ctx, source: source, includePaths: includePaths, databasePath: databasePath, fresh: fresh) { text, fraction in
                    Task { @MainActor in
                        guard self.routingProgress[ctx.id] != nil else { return }
                        self.routingProgress[ctx.id] = text
                        self.routingFraction[ctx.id] = fraction
                    }
                }
                try RoadDataStore.replace(packId: ctx.id, parts: parts)
                await OfflineRouter.shared.invalidate()
                let size = ByteCountFormatter.string(fromByteCount: Int64(parts.reduce(0) { $0 + $1.data.count }), countStyle: .file)
                let fallback = used == source ? "" : (used == .tiles
                    ? String(localized: " — aus Kartenkacheln, weil die eingestellte Quelle nicht ging")
                    : String(localized: " — aus Overpass, weil die eingestellte Quelle nicht ging"))
                lastMessage = String(localized: "Offline-Routing für „\(ctx.name)“ ist bereit (\(size)\(fallback)).")
            } catch {
                lastMessage = String(localized: "Straßennetz für „\(ctx.name)“ konnte nicht geladen werden (Kachel- und Overpass-Server nicht erreichbar?). Über das Menü des Pakets später erneut versuchen.")
            }
            fetchingRouting.remove(ctx.id)
            routingProgress[ctx.id] = nil
            routingFraction[ctx.id] = nil
            refresh()
        }
    }

    /** Baut das Straßennetz aus [source], bei Fehler aus der anderen Quelle. Läuft nicht auf dem Main-Thread. */
    private nonisolated static func buildRoadData(
        _ ctx: OfflinePackContext, source: OfflineRoadSource, includePaths: Bool, databasePath: String?, fresh: Bool,
        progress: @escaping (String, Double) -> Void
    ) async throws -> (parts: [(info: RoadDataInfo, data: Data)], used: OfflineRoadSource) {
        let order: [OfflineRoadSource] = source == .tiles ? [.tiles, .overpass] : [.overpass, .tiles]
        var lastError: Error = AppError.noResults
        for candidate in order {
            try Task.checkCancellation()
            do {
                switch candidate {
                case .tiles:
                    let parts = try await TileRoadBuilder.download(ctx.boundingBox, includePaths: includePaths, databasePath: databasePath,
                                                                   preferNetwork: fresh, progress: progress)
                    return (parts.enumerated().map { i, part in
                        (RoadDataInfo(id: "\(ctx.id)_\(i)", boundingBox: part.boundingBox, nodeCount: part.nodeCount, createdAt: Date(), packId: ctx.id), part.data)
                    }, .tiles)
                case .overpass:
                    let (data, nodeCount) = try await RoadDataBuilder.download(ctx.boundingBox, includePaths: includePaths) { done, total in
                        progress("Overpass \(done)/\(total)", Double(done) / Double(max(total, 1)))
                    }
                    return ([(RoadDataInfo(id: ctx.id, boundingBox: ctx.boundingBox, nodeCount: nodeCount, createdAt: Date(), packId: ctx.id), data)], .overpass)
                }
            } catch {
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /**
     * Suchdaten abschnittsweise (≈ 0,25°, ca. 28 × 17 km) statt als eine große Abfrage: liefert einen
     * echten Fortschritt für die Prozentanzeige, und ein überlasteter Server bricht nicht gleich
     * alles ab. Orte auf Abschnittsgrenzen werden entdoppelt.
     */
    private nonisolated static func fetchPlacesInChunks(_ bbox: BoundingBox, progress: @escaping (Double) -> Void) async throws -> [OverpassPlace] {
        let chunks = RoadDataBuilder.chunks(bbox, size: 0.25)
        var seen = Set<OverpassPlace>()
        var places: [OverpassPlace] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            for place in try await fetchChunkWithRetry(chunk) where seen.insert(place).inserted {
                places.append(place)
            }
            progress(Double(i + 1) / Double(chunks.count))
        }
        return places
    }

    /** Server voll (504/429) → derselbe Abschnitt nach einer Pause nochmal, statt alles abzubrechen. */
    private nonisolated static func fetchChunkWithRetry(_ chunk: BoundingBox) async throws -> [OverpassPlace] {
        let pauses: [UInt64] = [8, 20, 40]
        for attempt in 0...pauses.count {
            do {
                return try await OverpassClient.fetchNamedPlaces(chunk)
            } catch AppError.http(let code) where (code == 504 || code == 429) && attempt < pauses.count {
                try await Task.sleep(nanoseconds: pauses[attempt] * 1_000_000_000)
            }
        }
        throw AppError.noResults
    }

    private func findPack(_ id: String) -> MLNOfflinePack? {
        MLNOfflineStorage.shared.packs?.first { Self.context(of: $0)?.id == id }
    }

    private func handleProgress(_ pack: MLNOfflinePack?) {
        guard let pack, let ctx = Self.context(of: pack) else { return }
        let completed = pack.progress.countOfResourcesCompleted
        if lastProgressAt[ctx.id]?.0 != completed {
            lastProgressAt[ctx.id] = (completed, Date())
        }
        if pack.state == .complete {
            lastProgressAt[ctx.id] = nil
            // MapLibre meldet "fertig" u.U. mehrfach — Suchdaten nur einmal holen.
            if OfflinePlacesStore.shared.count(regionId: ctx.id) == 0 {
                refreshSearchData(ctx)
            }
            if !RoadDataStore.has(ctx.id) {
                refreshRoutingData(ctx)
            }
        }
        refresh()
    }

    private func checkStalls() {
        let now = Date()
        for (id, entry) in lastProgressAt where now.timeIntervalSince(entry.1) > Self.stallTimeout {
            lastProgressAt[id] = nil
            guard let pack = findPack(id), pack.state == .active else { continue }
            pack.suspend()
            lastMessage = String(localized: "Download hängt seit 2 Minuten (Kachelserver überlastet?). Pausiert — später fortsetzen oder kleinere Zoomstufe wählen.")
            refresh()
        }
    }
}
