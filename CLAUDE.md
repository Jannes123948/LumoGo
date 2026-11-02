# LumoGo (iOS) – Arbeitsnotizen für Claude

SwiftUI-Navi-App (Anzeigename **LumoGo**, intern `OsmNav`/`com.jannehorst.osmnav`, iOS 16+). Karte: MapLibre,
Routing: OSRM, Suche: Nominatim/Overpass. Details: `README.md`. Sprache der Oberfläche/Doku: **Deutsch**
(Quellsprache), Englisch über String-Kataloge. Der Nutzer schreibt Deutsch → auf Deutsch antworten.

> **Hinweis:** Es gibt eine iOS-15-Kopie in `/Users/janneshorst/Downloads/LumoGo-iOS15` (abgeleitet von diesem Stand,
> Siri/Live-Aktivität/Sperrbildschirm-Widgets nur ab iOS 16). Änderungen hier nicht automatisch dort.

## Rahmenbedingungen (wichtig)
- **Kostenloses Apple-Developer-Konto** → *keine* iCloud-Entitlements (Signing bricht). `CloudSync.swift` ist
  vorhanden, aber **ausgeschaltet** (kein Schalter in den Einstellungen, kein Entitlement). Nicht wieder einbauen,
  außer der Nutzer hat ein bezahltes Konto. Ersatz: Datensicherung als Datei (`BackupManager`).
- Kein CarPlay, kein PiP (siehe README).
- **Kein Git-Repo.** Sicherungen vor großen Umbauten manuell in den Scratchpad kopieren.
- Der Nutzer wählt Features aus Vorschlagslisten („nr 1 nr 3 …“) – nicht ungefragt Neues einbauen.

## Bauen / Prüfen
```
xcodebuild -project OsmNav.xcodeproj -scheme OsmNav -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD"
```
Neue Dateien in `OsmNav/`, `Shared/`, `LumoGoWidgets/`, `LumoGoShare/` werden automatisch mitgebaut (synchronisierte Ordner).
Nichts davon wurde bisher auf einem echten Gerät getestet – nur Simulator-Kompilierung.

## Übersetzungen
Katalog `OsmNav/Resources/Localizable.xcstrings` (de = Schlüssel, en = Übersetzung). `Tools/l10n.py` erwartet einen
**iphoneos**-Build; mit Simulator-Build stattdessen die `.stringsdata` unter
`~/Library/Developer/Xcode/DerivedData/OsmNav-*/Build/Intermediates.noindex/OsmNav.build/Debug-iphonesimulator/…`
auslesen und fehlende Schlüssel direkt per Skript in den Katalog schreiben (Format: `localizations.de/en.stringUnit`).
Interpolationen heißen `%@` / `%lld`. Siri-Sätze: `OsmNav/Resources/en.lproj/AppShortcuts.strings`
(max. **10** AppShortcuts pro App – aktuell 10 belegt: Home, Favorit, Tanken, Suche, Ankunft, Auto, Zum Auto,
Beenden, Wie geht es weiter, Markieren).
**Ändert sich ein langer Footer-Text, ändert sich sein Schlüssel** → neue Übersetzung nötig, alten Eintrag löschen.

## In dieser Arbeitsphase gebaut (alle kompilieren)
| Feature | Dateien / Stelle |
|---|---|
| Route meiden (Maut/Autobahn/Fähre) | `Routing/RouteAvoid.swift` (`ValhallaClient`, `RouteAvoidOptions`, `OsrmRoute.mergingLegs`), `RouteFetcher.swift`, Menü `AvoidMenu` in `RoutePanel.swift`, Einstellungen |
| Blitzer-Warnung | `HazardKind.speedCamera` (`Routing/Hazards.swift`), Overpass-Abfrage in `Routing/SpeedLimits.swift`; **Standard aus** (Rechtslage DE/CH) |
| Eigene Markierungen | `Model/MapMarker.swift`, `MarkerStore` (in `Stores/Stores.swift`), `Views/MarkersSheet.swift`, Pins über die Favoriten-Ebene (ID-Präfix `marker:`), Warnung via `markerHazards` im `AppModel` |
| Datensicherung (JSON) | `Stores/BackupManager.swift`, `BackupSettingsPage` in `SettingsView.swift` |
| Statistik (Zeitraum/Kennzahl) | `Views/TripStatsView.swift` (`TripStats.Period/Metric/Bucket`) |
| Siri-Intents | `App/Shortcuts.swift` (`StopNavigationIntent`, `NextInstructionIntent`, `AddMarkerIntent`; `ToggleVoiceIntent`, `SearchAlongRouteIntent` nur in Kurzbefehle) |
| Ausfahrts-Spurhinweis | `AppModel.updateExitHint`, `MotorwayInfo.exitHintSentence/exitIsOnLeft` |
| Tempo-Toleranz nach Straßenart | `AppSettings.tolerance(limit:motorway:)`, `AppModel.updateSpeed` |
| Pausen-Erinnerung | `AppModel.updateBreakReminder` (reine Fahrzeit, Stillstand >15 min setzt zurück) |
| Einstellungen als Menüs | `Views/SettingsView.swift`: Navigation, Karte, Design & Farben, Suche & Orte sind Hubs mit Unterseiten. **Nur „Sprachausgabe“ und „Tempolimit“ sind noch einseitig.** |

## Bekannte Eigenheiten / Fallstricke
- **OSRM-Demo-Server unterstützt kein `exclude=`** und liefert keine `classes`. „Meiden“ läuft deshalb über Valhalla
  (`valhalla1.openstreetmap.de`, nur Streckenverlauf) → Zwischenpunkte (≤ ~45, ≥ 3 km Abstand) → OSRM; danach
  werden die Zwischen-Etappen wieder zusammengeführt. Offline-Routing und GPX-Touren ignorieren „Meiden“.
- `System-Python 3.9` hat TLS-Probleme → für HTTP-Tests `curl` benutzen.
- Overpass-Hazard-Abfrage steckt in `SpeedLimitMap.load` (`includeHazards = hazardWarnings || speedCameraWarnings`).
- `HazardDetector.project(... maxOffset:)`: Blitzer/Markierungen 40 m, sonst 20 m, Schulen 80 m.
- Zsh: bei `grep --include=*.swift` Glob-Fehler → Muster quoten oder `grep -r` ohne `--include`.
- `Date().formatted(...)`/`String(localized:)` werden überall für Texte genutzt, die Sprachausgabe ebenfalls (`say(String(localized:…))`).

## Backups (Scratchpad, nur diese Session nützlich)
`/private/tmp/claude-501/-Users-janneshorst-Downloads-LumoGo-0-0-9-1/c009770b-a9ef-4c44-95ab-98dfcadeec5d/scratchpad/`
→ `SettingsView.swift.bak`, `.bak2` (vor den Menü-Umbauten).

## Offene Ideen (Nutzer hat noch nicht gewählt)
Zuletzt vorgeschlagen, noch nichts davon gebaut:
1. Zwischenstopps per Drag & Drop umsortieren + „Reihenfolge optimieren“
2. Geschwindigkeits-Chronik pro Fahrt (Tempo über Strecke, Überschreitungen rot)
3. Rückweg mit einem Tipp („Zurück zum Start“)
4. Ladesäulen-Planung für E-Autos (Reichweite/Akkustand)
5. Fahrstil-Auswertung (Wochenübersicht)
6. Abfahrtszeit-Vergleich (jetzt / +30 / +60 min, nur Wetter/Tageszeit, kein Live-Verkehr)
7. Pendler-Karte nach Tageszeit
8. Kalender-Abfahrtserinnerung („Jetzt losfahren“)
9. Mehrtages-Touren in Etappen
10. Markierungen per Langdruck an beliebigen Punkten
11. Listen/Sammlungen (z. B. „Urlaub 2026“) mit Route durch alle Punkte
12. Foto an Markierung (lokal)
13. Widget „Nächste Fahrt“, Teilen einer Fahrt als Bild, Jahresrückblick
14. Automatisch Tag/Nacht; Apple-Watch-Haptik (mit Gratis-Konto schwierig)
Empfohlen wurden zuletzt: Nr. 1, 3, 2.

## Nächste Schritte vor einem Release
- Auf echtem iPhone testen: Meiden (lange Route!), Blitzer/Markierungen-Warnung, Ausfahrts-Hinweis, Pausen-Erinnerung,
  Siri-Sätze, Datensicherung (Export → Import), neue Einstellungsmenüs (Optik/Navigation).
- `python3 Tools/l10n.py check` nach einem iphoneos-Build.
- „Sprachausgabe“ und „Tempolimit“ ggf. ebenfalls in Unterseiten teilen (Nutzer hatte „alle“ gesagt, wir haben beide bewusst ausgelassen).
