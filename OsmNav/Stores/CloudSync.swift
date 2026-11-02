import Foundation
import UIKit

/**
 * iCloud-Sync (iPhone ↔ iPad) für Favoriten, gespeicherte Routen, Fahrtenbuch und Parkplatz über den
 * iCloud-Schlüssel-Wert-Speicher (`NSUbiquitousKeyValueStore`, max. 1 MB — reicht für diese Listen).
 *
 * Je Liste gilt „letzte Änderung gewinnt“ (Zeitstempel je Schlüssel). Beim ersten Einschalten werden
 * die Listen beider Geräte **zusammengeführt** (nichts geht verloren). Nicht synchronisiert werden
 * GPX-Touren und aufgezeichnete Strecken (große Dateien) sowie die Einstellungen.
 */
enum CloudSync {
    static let settingsKey = "icloud_sync"
    /** Nach jeder von iCloud übernommenen Änderung (Listen neu lesen). */
    static let changed = Notification.Name("LumoGoCloudSyncChanged")

    private static let keys = ["osmnav_favorites", "osmnav_saved_routes", "osmnav_trips", "osmnav_parked_car"]
    private static let maxBytes = 450_000
    private static var observers: [NSObjectProtocol] = []
    private static var store: NSUbiquitousKeyValueStore { .default }
    private static var defaults: UserDefaults { .standard }

    static var isEnabled: Bool { defaults.bool(forKey: settingsKey) }
    /** Auf dem Gerät ist ein iCloud-Konto angemeldet. */
    static var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    private static func localStamp(_ key: String) -> String { "cloud_ts_" + key }
    private static func remoteStamp(_ key: String) -> String { key + "_ts" }
    private static func mergedFlag(_ key: String) -> String { "cloud_merged_" + key }

    // MARK: - Start / Ein- und Ausschalten

    /** Beim App-Start: auf Änderungen anderer Geräte lauschen. */
    static func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store, queue: .main
        ) { note in
            guard isEnabled else { return }
            let changedKeys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            let affected = Set(changedKeys.map { $0.hasSuffix("_ts") ? String($0.dropLast(3)) : $0 })
            for key in keys where affected.contains(key) { pull(key) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            if isEnabled { store.synchronize() }
        })
        if isEnabled {
            store.synchronize()
            reconcile()
        }
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            store.synchronize()
            reconcile()
        } else {
            for key in keys { defaults.removeObject(forKey: mergedFlag(key)) }
        }
    }

    // MARK: - Lokale Änderung → iCloud

    /** Von den Stores nach jedem Speichern aufgerufen. */
    static func localChanged(_ key: String) {
        guard isEnabled, keys.contains(key) else { return }
        let now = Date().timeIntervalSince1970
        defaults.set(now, forKey: localStamp(key))
        if let data = defaults.data(forKey: key) {
            let outgoing = self.outgoing(key, data)
            guard outgoing.count <= maxBytes else { return }
            store.set(outgoing, forKey: key)
        } else {
            store.removeObject(forKey: key)
        }
        store.set(now, forKey: remoteStamp(key))
        store.synchronize()
    }

    // MARK: - iCloud → lokal

    /** Übernimmt die iCloud-Fassung, wenn sie neuer ist als die lokale. */
    private static func pull(_ key: String) {
        let remoteTime = store.double(forKey: remoteStamp(key))
        guard remoteTime > defaults.double(forKey: localStamp(key)) else { return }
        apply(key, remote: store.data(forKey: key), stamp: remoteTime)
    }

    private static func apply(_ key: String, remote: Data?, stamp: Double) {
        if let remote, let incoming = incoming(key, remote) {
            defaults.set(incoming, forKey: key)
        } else if remote == nil {
            defaults.removeObject(forKey: key)
        } else {
            return // unlesbar — lokale Daten behalten
        }
        defaults.set(stamp, forKey: localStamp(key))
        notifyChanged(key)
    }

    private static func notifyChanged(_ key: String) {
        switch key {
        case "osmnav_favorites":
            FavoritesStore.onChange?()
            NotificationCenter.default.post(name: FavoritesStore.changed, object: nil)
        case "osmnav_parked_car":
            let car = ParkingStore.load()
            if car == nil { ParkingStore.cancelReminder() }
            ParkingStore.publish(car)
        default:
            break
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // MARK: - Erstabgleich

    /** Beim Einschalten bzw. Start: fehlende Seite auffüllen, beim ersten Mal beide Seiten zusammenführen. */
    private static func reconcile() {
        for key in keys {
            let remote = store.data(forKey: key)
            let local = defaults.data(forKey: key)
            let alreadyMerged = defaults.bool(forKey: mergedFlag(key))
            if remote == nil && local == nil { defaults.set(true, forKey: mergedFlag(key)); continue }
            if alreadyMerged {
                // Normalbetrieb: neuere Fassung gewinnt.
                let remoteTime = store.double(forKey: remoteStamp(key))
                if remoteTime > defaults.double(forKey: localStamp(key)) { pull(key) }
                else if remoteTime < defaults.double(forKey: localStamp(key)) { localChanged(key) }
                continue
            }
            defaults.set(true, forKey: mergedFlag(key))
            guard let remote else { localChanged(key); continue }
            guard let local else { apply(key, remote: remote, stamp: store.double(forKey: remoteStamp(key))); continue }
            if let merged = merge(key, local: local, remote: remote) {
                defaults.set(merged, forKey: key)
                notifyChanged(key)
            }
            localChanged(key)
        }
    }

    // MARK: - Zusammenführen und Umwandeln

    private static func merge(_ key: String, local: Data, remote: Data) -> Data? {
        switch key {
        case "osmnav_favorites":
            return union(local, remote, id: { (f: Favorite) in f.id }, order: nil)
        case "osmnav_saved_routes":
            guard let remoteRoutes = try? JSONDecoder().decode([SavedRoute].self, from: remote),
                  let localRoutes = try? JSONDecoder().decode([SavedRoute].self, from: local) else { return nil }
            let ids = Set(localRoutes.map(\.id))
            let all = localRoutes + remoteRoutes.filter { !ids.contains($0.id) && !$0.isTour }
            return try? JSONEncoder().encode(all.sorted { $0.createdAt > $1.createdAt })
        case "osmnav_trips":
            return union(local, remote, id: { (t: Trip) in t.id }, order: { $0.timestamp > $1.timestamp }, limit: 200)
                .flatMap { incoming(key, $0) }
        case "osmnav_parked_car":
            guard let a = try? JSONDecoder().decode(ParkedCar.self, from: local),
                  let b = try? JSONDecoder().decode(ParkedCar.self, from: remote) else { return nil }
            return b.date > a.date ? remote : local
        default:
            return nil
        }
    }

    private static func union<T: Codable>(_ local: Data, _ remote: Data, id: (T) -> String,
                                          order: ((T, T) -> Bool)?, limit: Int = .max) -> Data? {
        guard let a = try? JSONDecoder().decode([T].self, from: local),
              let b = try? JSONDecoder().decode([T].self, from: remote) else { return nil }
        let known = Set(a.map(id))
        var all = a + b.filter { !known.contains(id($0)) }
        if let order { all = Array(all.sorted(by: order).prefix(limit)) }
        return try? JSONEncoder().encode(all)
    }

    /** Was in iCloud landet: keine GPX-Touren (ihre Spur liegt nur als lokale Datei vor). */
    private static func outgoing(_ key: String, _ data: Data) -> Data {
        guard key == "osmnav_saved_routes",
              let routes = try? JSONDecoder().decode([SavedRoute].self, from: data),
              let filtered = try? JSONEncoder().encode(routes.filter { !$0.isTour }) else { return data }
        return filtered
    }

    /** Was aus iCloud übernommen wird: lokale Touren behalten, Strecken-Flag nach lokaler Datei setzen. */
    private static func incoming(_ key: String, _ data: Data) -> Data? {
        switch key {
        case "osmnav_saved_routes":
            guard let remote = try? JSONDecoder().decode([SavedRoute].self, from: data) else { return nil }
            let localTours = SavedRoutesStore.list().filter(\.isTour)
            return try? JSONEncoder().encode((remote.filter { !$0.isTour } + localTours).sorted { $0.createdAt > $1.createdAt })
        case "osmnav_trips":
            guard let trips = try? JSONDecoder().decode([Trip].self, from: data) else { return nil }
            let fixed = trips.map { trip -> Trip in
                var t = trip
                t.hasTrack = TripTrackStore.exists(tripId: trip.id) ? true : nil
                return t
            }
            return try? JSONEncoder().encode(fixed)
        default:
            return data
        }
    }
}
