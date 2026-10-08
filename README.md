# LumoGo (iOS)

Die iOS-App heißt **LumoGo** (Anzeigename unter dem Icon). Intern heißen Projekt, Target und
Bundle-ID weiter `OsmNav`/`com.jannehorst.osmnav` — eine neue Bundle-ID wäre für iOS eine neue App
(Favoriten/Einstellungen weg).


SwiftUI-Port der Android-App (Minimum **iOS 16**). Karte: MapLibre Native iOS (Swift Package, wird
von Xcode beim ersten Öffnen automatisch geladen). Kartenkacheln: OpenFreeMap, Routing: OSRM,
Suche: Nominatim + Overpass.

## Öffnen & starten
1. `OsmNav.xcodeproj` in Xcode öffnen (Swift Package „MapLibre“ wird automatisch aufgelöst).
2. Target **OsmNav** → *Signing & Capabilities* → eigenes Team wählen (für echtes iPhone nötig;
   ggf. Bundle-ID `com.jannehorst.osmnav` anpassen, falls sie schon vergeben ist).
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

Das Xcode-Projekt nutzt „synchronisierte Ordner“ (Xcode 16): neue Dateien in `ios/OsmNav/` werden
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
