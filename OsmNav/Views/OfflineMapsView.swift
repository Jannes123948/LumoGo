import SwiftUI

/** Zoom-Presets wie in der Android-Version. */
enum ZoomPreset: String, CaseIterable, Identifiable {
    case overview, standard, detailed, navigation, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "Übersicht (6–10)"
        case .standard: return "Standard (6–12)"
        case .detailed: return "Sehr detailliert (6–14)"
        case .navigation: return "Navigation (6–16)"
        case .custom: return "Benutzerdefiniert …"
        }
    }

    var range: ClosedRange<Int>? {
        switch self {
        case .overview: return 6...10
        case .standard: return 6...12
        case .detailed: return 6...14
        case .navigation: return 6...16
        case .custom: return nil
        }
    }
}

/** Offline-Kartenpakete: Gebiet suchen oder aktuellen Ausschnitt wählen, herunterladen, verwalten. */
struct OfflineMapsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = OfflineMapsManager.shared

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false
    @State private var selectedName = ""
    @State private var selectedBox: BoundingBox?
    @State private var preset = ZoomPreset.standard
    @State private var customMin = 6
    @State private var customMax = 14
    @State private var showAreaPicker = false

    private var zoomRange: ClosedRange<Int> { preset.range ?? min(customMin, customMax)...max(customMin, customMax) }

    var body: some View {
        NavigationStack {
            Form {
                if settings.mapEngine == .osm {
                    Section {
                        Label("Offline-Kartenpakete werden nur in der Vektorkarte (MapLibre) angezeigt — der OpenStreetMap-Server erlaubt keine Massen-Downloads. Suche und Routing funktionieren offline aber auch mit der OSM-Karte.", systemImage: "info.circle")
                            .font(.footnote)
                    }
                }
                Section("Gebiet wählen") {
                    HStack {
                        TextField("Stadt, Landkreis, Bundesland …", text: $query)
                            .submitLabel(.search)
                            .onSubmit(search)
                        if searching { ProgressView() } else {
                            Button("Suchen", action: search).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    ForEach(results.filter { $0.boundingBox != nil }) { result in
                        Button {
                            selectedName = result.displayName.components(separatedBy: ",").first ?? result.displayName
                            selectedBox = result.boundingBox
                            results = []
                        } label: {
                            Text(result.displayName).font(.subheadline).foregroundStyle(.primary)
                        }
                    }
                    Button {
                        showAreaPicker = true
                    } label: {
                        Label("Eigenen Bereich auf der Karte wählen", systemImage: "square.dashed")
                    }
                }

                if let box = selectedBox {
                    Section("Download") {
                        TextField("Name", text: $selectedName)
                        Button {
                            showAreaPicker = true
                        } label: {
                            Label("Bereich auf der Karte anpassen", systemImage: "square.dashed")
                        }
                        Picker("Zoomstufen", selection: $preset) {
                            ForEach(ZoomPreset.allCases) { Text($0.label).tag($0) }
                        }
                        if preset == .custom {
                            Stepper("Min. Zoom: \(customMin)", value: $customMin, in: 1...16)
                            Stepper("Max. Zoom: \(customMax)", value: $customMax, in: 1...16)
                        }
                        let tiles = TileMath.tileCount(box, minZoom: zoomRange.lowerBound, maxZoom: zoomRange.upperBound)
                        Text("≈ \(tiles.formatted()) Kacheln")
                            .foregroundStyle(tiles > 300_000 ? .red : .secondary)
                        if tiles > 300_000 {
                            Text("Sehr großes Paket — der kostenlose Kachelserver kann dabei hängen bleiben. Für Bundesländer besser max. Zoom 14 wählen.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button {
                            manager.download(
                                name: selectedName.isEmpty ? "Kartenpaket" : selectedName,
                                bbox: box,
                                minZoom: zoomRange.lowerBound,
                                maxZoom: zoomRange.upperBound,
                                styleURL: colorScheme == .dark ? MapController.darkStyleURL : MapController.lightStyleURL
                            )
                            selectedBox = nil
                            query = ""
                        } label: {
                            Label("Herunterladen", systemImage: "arrow.down.circle.fill")
                        }
                        Text("Danach werden Suchdaten und das Straßennetz fürs Offline-Routing geladen. Die App muss währenddessen geöffnet bleiben — sonst pausiert iOS den Download.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Heruntergeladene Pakete") {
                    if manager.packs.isEmpty {
                        Text("Noch keine Offline-Karten.").foregroundStyle(.secondary)
                    }
                    ForEach(manager.packs) { pack in
                        PackRow(pack: pack)
                    }
                    .onDelete { offsets in offsets.map { manager.packs[$0] }.forEach(manager.delete) }
                }
            }
            .navigationTitle("Offline-Karten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .onAppear { manager.refresh() }
            .fullScreenCover(isPresented: $showAreaPicker) {
                OfflineAreaPickerView(
                    initialBounds: selectedBox ?? model.map.visibleBounds,
                    existingPacks: manager.packs.map(\.context.boundingBox),
                    preset: $preset,
                    customRange: min(customMin, customMax)...max(customMin, customMax)
                ) { box in
                    if selectedBox == nil || selectedName.isEmpty {
                        selectedName = "Eigener Bereich \(Date().formatted(date: .numeric, time: .omitted))"
                    }
                    selectedBox = box
                    results = []
                }
            }
            .alert("Offline-Karten", isPresented: Binding(get: { manager.lastMessage != nil }, set: { if !$0 { manager.lastMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(manager.lastMessage ?? "")
            }
        }
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            results = (try? await NominatimClient.search(q)) ?? []
            searching = false
            if results.allSatisfy({ $0.boundingBox == nil }) { manager.lastMessage = "Kein passendes Gebiet gefunden." }
        }
    }
}

private struct PackRow: View {
    @ObservedObject private var manager = OfflineMapsManager.shared
    let pack: OfflinePackInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(pack.context.name).font(.headline).lineLimit(1)
                Spacer()
                Menu {
                    if !pack.isComplete {
                        if pack.isActive {
                            Button("Pausieren") { manager.pause(pack) }
                        } else {
                            Button("Fortsetzen") { manager.resume(pack) }
                        }
                    }
                    Button("Suchdaten aktualisieren") { manager.refreshSearchData(pack.context) }
                    Button(pack.hasRouting ? "Routing-Daten aktualisieren" : "Routing-Daten laden") { manager.refreshRoutingData(pack.context) }
                    Button("Löschen", role: .destructive) { manager.delete(pack) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            Text("Zoom \(pack.context.minZoom)–\(pack.context.maxZoom) · \(ByteCountFormatter.string(fromByteCount: Int64(pack.bytes), countStyle: .file)) · \(pack.placesCount) Orte offline suchbar")
                .font(.caption).foregroundStyle(.secondary)
            if let progress = manager.routingProgress[pack.id] {
                Label("Straßennetz fürs Offline-Routing: \(progress)", systemImage: "arrow.triangle.turn.up.right.diamond")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if pack.isComplete {
                Label(pack.hasRouting ? "Offline-Routing verfügbar" : "Kein Offline-Routing (Menü → Routing-Daten laden)",
                      systemImage: pack.hasRouting ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(pack.hasRouting ? Color.green : Color.secondary)
            }
            if !pack.isComplete {
                ProgressView(value: pack.fraction) {
                    Text("\(pack.completed.formatted()) / \(pack.expected.formatted()) · \(pack.isActive ? "lädt …" : "pausiert")")
                        .font(.caption2)
                }
            }
        }
    }
}
