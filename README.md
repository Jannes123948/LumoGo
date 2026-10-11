# LumoGo (iOS)

Die iOS-App heißt **LumoGo** (Anzeigename unter dem Icon). Intern heißen Projekt, Target und
Bundle-ID weiter `OsmNav`/`com.jannehorst.osmnav` — eine neue Bundle-ID wäre für iOS eine neue App
(Favoriten/Einstellungen weg).


SwiftUI-Port der Android-App (Minimum **iOS 16**). Karte: MapLibre Native iOS (Swift Package, wird
von Xcode beim ersten Öffnen automatisch geladen). Kartenkacheln: OpenFreeMap, Routing: OSRM,
Suche: Nominatim + Overpass.

## Öffnen & starten
1. `OsmNav.xcodeproj` in Xcode öffnen (Swift Package „MapLibre“ wird automatisch aufgelöst).
2. Targets **OsmNav**, **LumoGoWidgets** UND **LumoGoShare** → *Signing & Capabilities* → jeweils eigenes
   Team wählen (für echtes iPhone nötig; ggf. Bundle-IDs `com.jannehorst.osmnav` / `….osmnav.widgets` /
   `….osmnav.share` anpassen — die Erweiterungs-IDs müssen mit der App-ID beginnen). Alle drei nutzen die
   App Group `group.com.jannehorst.osmnav` (Navigations-Widget, geteilte Orte) — Xcode legt sie beim
   automatischen Signieren an; bei geänderter Bundle-ID auch die Gruppe in `OsmNav.entitlements`,
   `LumoGoWidgets.entitlements`, `LumoGoShare.entitlements` und `Shared/NavWidgetState.swift` anpassen.
3. Gerät/Simulator wählen → Run (⌘R). Im Simulator Standort über *Features → Location* setzen.

## Struktur (`OsmNav/`)
| Ordner | Inhalt (Android-Pendant) |
|---|---|
| `App/` | `OsmNavApp` (Einstieg), `AppModel` (Logik aus `MainActivity.kt`) |
| `Model/`, `Util/` | `LatLon`, OSRM-Modelle, `GeoUtils`, `FormatUtils` |
| `Network/` | `OsrmClient`, `NominatimClient`, `OverpassClient`, `PoiSearchClient`/`SearchFetcher` |
| `Routing/` | `RouteProgressTracker`, `InstructionFormatter`, Icons, NavZoom, BearingFilter, RoadSnapper, Höhenprofil |
| `Stores/` | Favoriten, Suchverlauf, Fahrtenbuch (UserDefaults), Offline-Suchdaten (JSON) |
| `Services/` | Einstellungen, Standort (CoreLocation), Sprachausgabe (AVSpeechSynthesizer) |
| `Map/` | `MapController` (MapLibre-Quellen/Layer/Kamera), SwiftUI-Wrapper |
| `Offline/` | Offline-Kartenpakete (`MLNOfflineStorage`), Straßennetz + Offline-Router |
| `Views/` | SwiftUI-Oberflächen |

Außerdem: `LumoGoWidgets/` = Widget-Erweiterung (Navigation auf Sperrbildschirm/Dynamic Island,
Schnellzugriff-Widget), `LumoGoShare/` = Teilen-Erweiterung (Orte aus Apple Karten, Google Maps & Co.
übernehmen), `Shared/` = Code für App UND Erweiterungen (Live-Aktivitäts-Daten, `lumogo://`-Links, geteilte Orte).

**Sprachen**: Deutsch (Quellsprache) und Englisch — Einstellungen → „Sprache“ (gilt ab dem nächsten Start).
Übersetzungen in den String-Katalogen `OsmNav/Resources/Localizable.xcstrings`, `LumoGoWidgets/Localizable.xcstrings`,
`LumoGoShare/Localizable.xcstrings`, Siri-Sätze in `OsmNav/Resources/en.lproj/AppShortcuts.strings`. Nach neuen
Texten: bauen, dann `python3 Tools/l10n.py check` (zeigt fehlende Übersetzungen und nicht übersetzbare Texte).

Das Xcode-Projekt nutzt „synchronisierte Ordner“ (Xcode 16): neue Dateien in `OsmNav/`, `Shared/`, `LumoGoWidgets/` und `LumoGoShare/` werden
automatisch mitgebaut, ohne sie im Projekt eintragen zu müssen.

## Unterschiede zur Android-Version
- **Zwei Karten wie auf Android** (Einstellungen → „Karte“): Vektorkarte (MapLibre, 3D) oder
  klassische OpenStreetMap-Karte (2D, nordausgerichtet, dunkel = invertierte Farben). osmdroid gibt
  es nicht für iOS — die OSM-Kacheln werden ebenfalls über MapLibre angezeigt (`Resources/osm_raster_*.json`),
  dadurch funktionieren Route/Navigation in beiden ohne doppelten Code. Offline-Kartenpakete gibt
  es wie auf Android nur für die Vektorkarte (OSM-Server verbietet Massen-Downloads).
- **Offline-Routing ohne BRouter** (das gibt es nur für Android): Beim Download eines Kartenpakets
  lädt die App zusätzlich das Straßennetz (Overpass) und routet ohne Internet mit einem eigenen
  A*-Router (`Offline/OfflineRouter.swift`) inkl. selbst erzeugter Abbiegehinweise. Keine
  Fahrstreifen-Empfehlung, keine Alternativrouten, Fahrzeiten nur geschätzt (Tempo je Straßenklasse/
  `maxspeed`).
- **Kein CarPlay**: bräuchte ein von Apple freizuschaltendes Navigations-Entitlement.
- **Kein Bild-im-Bild**: iOS erlaubt PiP nur für Video. Stattdessen laufen Standort und
  Sprachansagen bei aktiver Navigation im Hintergrund weiter (`UIBackgroundModes`).
- **Offline-Downloads** pausieren, wenn die App verlassen wird (kein Foreground-Service wie auf Android).
- UI nur auf Deutsch.
