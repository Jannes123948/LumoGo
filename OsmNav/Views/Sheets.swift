import SwiftUI
import UniformTypeIdentifiers

// MARK: - Favoriten

struct FavoritesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var favorites = FavoritesStore.list()
    @State private var savedRoutes = SavedRoutesStore.list()
    @State private var exporting = false
    /** Ein einziger Datei-Dialog: zwei `.fileImporter` an derselben Ansicht vertragen sich nicht. */
    @State private var importKind: ImportKind?
    @State private var savingRoute = false
    @State private var routeName = ""

    private enum ImportKind { case favorites, gpx }

    /** GPX hat keinen System-Typ; Dateien kommen aber oft als XML oder „beliebige Daten“ an. */
    private static let gpxTypes: [UTType] = [UTType(filenameExtension: "gpx"), .xml].compactMap { $0 }

    var body: some View {
        NavigationStack {
            List {
                if favorites.isEmpty {
                    Text("Noch keine Favoriten gespeichert.").foregroundStyle(.secondary)
                }
                ForEach(favorites) { favorite in
                    Button {
                        model.navigateToFavorite(favorite)
                        dismiss()
                    } label: {
                        Label(favorite.name, systemImage: favorite.isHome ? "house.fill" : "star.fill")
                            .foregroundStyle(.primary)
                    }
                }
                .onDelete { offsets in
                    offsets.map { favorites[$0].id }.forEach(FavoritesStore.remove)
                    favorites = FavoritesStore.list()
                }

                Section("Neuen Favoriten speichern") {
                    Button {
                        dismiss()
                        model.saveCurrentPositionAsFavorite()
                    } label: { Label("Aktuelle Position", systemImage: "location") }
                    Button {
                        model.pickingFavoriteLocation = true
                        dismiss()
                    } label: { Label("Auf der Karte wählen", systemImage: "hand.tap") }
                    Text("Tipp: Über den Stern neben einem Suchergebnis lässt sich auch eine Adresse speichern.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if savedRoutes.isEmpty {
                        Text("Noch keine Routen gespeichert.").foregroundStyle(.secondary)
                    }
                    ForEach(savedRoutes) { saved in
                        Button {
                            model.loadSavedRoute(saved)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(saved.name, systemImage: saved.isTour ? "point.topleft.down.curvedto.point.bottomright.up" : "signpost.right.fill")
                                Text(saved.isTour ? "GPX-Tour" : saved.stops.count == 1 ? "1 Ziel" : "\(saved.stops.count) Ziele")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .padding(.leading, 32)
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { savedRoutes[$0].id }.forEach(SavedRoutesStore.remove)
                        savedRoutes = SavedRoutesStore.list()
                    }
                    if !model.waypoints.isEmpty {
                        Button {
                            routeName = model.activeTour?.name ?? (model.waypoints.last?.label.components(separatedBy: ",").first ?? "")
                            savingRoute = true
                        } label: { Label("Aktuelle Route speichern", systemImage: "bookmark") }
                    }
                    Button { importKind = .gpx } label: { Label("GPX-Tour importieren", systemImage: "doc.badge.plus") }
                } header: {
                    Text("Gespeicherte Routen & Touren")
                } footer: {
                    Text("GPX-Touren aus Komoot, Strava, Outdooractive & Co. werden mit Ansagen abgefahren; die Originalspur erscheint gestrichelt auf der Karte.")
                }
                Section("Favoriten sichern") {
                    Button { exporting = true } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                    Button { importKind = .favorites } label: { Label("Importieren", systemImage: "square.and.arrow.down") }
                }
            }
            .navigationTitle("Favoriten & Routen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: JSONFile(data: FavoritesStore.exportJson()), contentType: .json, defaultFilename: "osmnav_favoriten") { result in
                if case .success = result { model.showToast(String(localized: "Favoriten exportiert.")) }
            }
            .fileImporter(isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
                          allowedContentTypes: importKind == .gpx ? Self.gpxTypes + [.data] : [.json]) { result in
                let kind = importKind
                importKind = nil
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else {
                    model.showToast(String(localized: "Datei konnte nicht gelesen werden."))
                    return
                }
                if kind == .gpx {
                    if model.importGPX(data, fileName: url.lastPathComponent) {
                        dismiss()
                    } else {
                        model.showToast(String(localized: "Keine GPX-Tour mit Wegpunkten gefunden."))
                    }
                } else if let count = try? FavoritesStore.importJson(data) {
                    favorites = FavoritesStore.list()
                    model.showToast(String(localized: "\(count) Favoriten importiert."))
                } else {
                    model.showToast(String(localized: "Import fehlgeschlagen."))
                }
            }
            .alert("Route speichern", isPresented: $savingRoute) {
                TextField("Name", text: $routeName)
                Button("Abbrechen", role: .cancel) {}
                Button("Speichern") {
                    model.saveCurrentRoute(name: routeName)
                    savedRoutes = SavedRoutesStore.list()
                }
            }
        }
    }
}

struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct FavoriteNameSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let pending: AppModel.PendingFavorite
    @State private var name = ""
    @State private var asHome = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Toggle("Als Zuhause festlegen", isOn: $asHome)
            }
            .navigationTitle("Favorit speichern")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        model.confirmFavorite(name: name, point: pending.point, asHome: asHome)
                        dismiss()
                    }
                }
            }
            .onAppear { name = pending.name }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - In der Nähe

struct NearbyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(NearbyCategory.allCases) { category in
                Button {
                    model.searchNearby(category)
                    dismiss()
                } label: {
                    Label(category.label, systemImage: category.symbol).foregroundStyle(.primary)
                }
            }
            .navigationTitle("In der Nähe suchen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Fahrtenbuch

struct TripHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var trips = TripHistoryStore.list()

    /** „8. Okt. 2026, 17:42 · 12,3 km · 18 Min. · Ø 41 km/h“ */
    static func summary(_ trip: Trip) -> String {
        var parts = [trip.timestamp.formatted(date: .abbreviated, time: .shortened),
                     FormatUtils.formatDistance(trip.drivenMeters ?? trip.distanceMeters),
                     FormatUtils.formatDuration(trip.durationSeconds)]
        if let avg = trip.averageKmh { parts.append("Ø \(Int(avg.rounded())) km/h") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            List {
                if !trips.isEmpty {
                    TripStatsSection(trips: trips)
                }
                if trips.isEmpty {
                    Text("Noch keine Fahrten. Fahrten werden nur bei tatsächlicher Ankunft gespeichert — mit Strecke, wenn „Strecke aufzeichnen“ an ist (Einstellungen → Navigation).")
                        .foregroundStyle(.secondary)
                }
                Section(trips.isEmpty ? "" : "Fahrten") {
                ForEach(trips) { trip in
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(trip.destinationName).font(.headline).lineLimit(2)
                                if trip.hasTrack == true {
                                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(Self.summary(trip)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { trips[$0].id }.forEach(TripHistoryStore.remove)
                    trips = TripHistoryStore.list()
                }
                }
            }
            .navigationTitle("Fahrtenbuch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Alle löschen", role: .destructive) {
                        TripHistoryStore.clear()
                        trips = []
                    }
                    .disabled(trips.isEmpty)
                }
            }
        }
    }
}
