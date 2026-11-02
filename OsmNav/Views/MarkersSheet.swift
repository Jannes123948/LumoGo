import SwiftUI

/** „Eigene Markierungen“: Blitzer, Baustellen, Gefahren, Parkplätze, Notizen — setzen, ansehen, löschen. */
struct MarkersSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var markers = MarkerStore.list()
    @State private var note = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Notiz (optional)", text: $note)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 12) {
                        ForEach(MarkerKind.allCases) { kind in
                            Button {
                                if model.addMarker(kind, note: note) {
                                    note = ""
                                    markers = MarkerStore.list()
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    FavoriteBadge(symbol: kind.symbol, colorHex: kind.colorHex, size: 40)
                                    Text(kind.label).font(.caption).foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("Hier markieren")
                } footer: {
                    Text("Setzt die Markierung an deinem aktuellen Standort. Blitzer, Baustellen und Gefahren melden sich auf deiner Route vorher (siehe Einstellungen → Navigation → Warnungen). Nur auf diesem Gerät.")
                }

                Section {
                    if markers.isEmpty {
                        Text("Noch keine Markierungen.").foregroundStyle(.secondary)
                    }
                    ForEach(markers) { marker in
                        Button {
                            model.showMarker(marker)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                FavoriteBadge(symbol: marker.kind.symbol, colorHex: marker.kind.colorHex)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(marker.title).foregroundStyle(.primary)
                                    Text(marker.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { model.removeMarker(id: markers[index].id) }
                        markers = MarkerStore.list()
                    }
                } header: {
                    Text("Meine Markierungen")
                }
            }
            .navigationTitle("Markierungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
