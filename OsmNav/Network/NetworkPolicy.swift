import Foundation

/**
 * Offline-Modus (Einstellungen → Karte → Offline):
 *  - „Nur Offline-Karten“: Kartenkacheln nur aus heruntergeladenen Paketen/Cache, keine Downloads.
 *  - „Komplett offline“: zusätzlich keine Anfragen für Routing, Suche, Overpass, Höhenprofil —
 *    die vorhandenen Ausweichwege (Offline-Router, Offline-Suche, Offline-Einrasten) greifen dann
 *    automatisch, weil [HTTP.data] sofort mit [AppError.offlineMode] scheitert.
 * Vom Nutzer gestartete Offline-Downloads (Kartenpakete, Such-/Routing-Daten) dürfen trotzdem ins
 * Netz — sonst ließe sich im Offline-Modus nichts nachladen.
 *
 * Wird aus Hintergrund-Threads gelesen (MapLibre-Netzwerk-Delegate): Einstellungen direkt aus
 * UserDefaults (thread-sicher), Download-Zähler hinter einem Lock.
 */
enum NetworkPolicy {
    static let offlineMapsKey = "offline_maps_only"
    static let fullyOfflineKey = "fully_offline"

    static var fullyOffline: Bool { UserDefaults.standard.bool(forKey: fullyOfflineKey) }
    static var offlineMaps: Bool { fullyOffline || UserDefaults.standard.bool(forKey: offlineMapsKey) }

    private static let lock = NSLock()
    private static var runningDataDownloads = 0
    private static var packDownloadsActive = false

    /** Läuft gerade ein vom Nutzer gestarteter Offline-Download? */
    static var downloadsActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return runningDataDownloads > 0 || packDownloadsActive
    }

    static func beginDataDownload() { lock.lock(); runningDataDownloads += 1; lock.unlock() }
    static func endDataDownload() { lock.lock(); runningDataDownloads = max(0, runningDataDownloads - 1); lock.unlock() }
    static func setPackDownloadsActive(_ active: Bool) { lock.lock(); packDownloadsActive = active; lock.unlock() }

    /** Darf die App (Routing, Suche, …) gerade ins Internet? */
    static var allowsAppRequests: Bool { !fullyOffline || downloadsActive }
    /** Darf die Karte gerade Kacheln aus dem Internet laden? */
    static var allowsMapRequests: Bool { !offlineMaps || downloadsActive }
}
