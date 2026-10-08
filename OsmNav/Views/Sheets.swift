import SwiftUI
import UniformTypeIdentifiers

// MARK: - Favoriten

struct FavoritesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var favorites = FavoritesStore.list()
    @State private var exporting = false
    @State private var importing = false

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
                Section("Sichern") {
                    Button { exporting = true } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                    Button { importing = true } label: { Label("Importieren", systemImage: "square.and.arrow.down") }
                }
            }
            .navigationTitle("Favoriten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: JSONFile(data: FavoritesStore.exportJson()), contentType: .json, defaultFilename: "osmnav_favoriten") { result in
                if case .success = result { model.showToast("Favoriten exportiert.") }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let count = try? FavoritesStore.importJson(data) {
                    favorites = FavoritesStore.list()
                    model.showToast("\(count) Favoriten importiert.")
                } else {
                    model.showToast("Import fehlgeschlagen.")
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
                if trips.isEmpty {
                    Text("Noch keine Fahrten. Fahrten werden nur bei tatsächlicher Ankunft gespeichert — mit Strecke, wenn „Strecke aufzeichnen“ an ist (Einstellungen → Navigation).")
                        .foregroundStyle(.secondary)
                }
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
