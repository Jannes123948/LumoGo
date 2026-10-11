import SwiftUI

/** „Auf der Route suchen“: Kategorie wählen, Treffer entlang der Strecke, Antippen = Zwischenstopp. */
struct AlongRouteSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var category: AlongRouteCategory = .fuel
    @State private var results: [AlongRoutePlace] = []
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AlongRouteCategory.allCases) { item in
                                Button {
                                    category = item
                                    load()
                                } label: {
                                    Label(item.label, systemImage: item.symbol)
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .foregroundStyle(item == category ? settings.buttonText : Color.primary)
                                        .background(item == category ? settings.accent : Color(.secondarySystemBackground), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                } footer: {
                    Text("Die nächsten \(settings.alongRouteKm) km, bis \(settings.alongRouteCorridor) m neben der Route\(category == .fuel && !settings.tankerkoenigKey.isEmpty ? " · mit Spritpreisen" : "").")
                }

                Section {
                    if loading {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Suche entlang der Route …").foregroundStyle(.secondary)
                        }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                        Button("Erneut versuchen") { load() }
                    } else if results.isEmpty {
                        Text("Nichts gefunden — in den Einstellungen (Navigation) lässt sich der Suchbereich vergrößern.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { place in
                        Button {
                            model.addStopOnRoute(place)
                            dismiss()
                        } label: {
                            row(place)
                        }
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle("Auf der Route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            .onAppear { if results.isEmpty && !loading { load() } }
            .onDisappear { task?.cancel() }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ place: AlongRoutePlace) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                Text(FormatUtils.formatDistance(place.alongMeters)).font(.subheadline.weight(.bold)).monospacedDigit()
                Text("+\(place.detourMinutes) Min.").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 66)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.subheadline.weight(.semibold)).lineLimit(2)
                if let fuelType = place.fuelType {
                    FuelPriceView(type: fuelType, price: place.price)
                } else if let detail = place.detail {
                    Text(detail).font(.caption).foregroundStyle(place.price != nil ? Color.green : .secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle.fill").foregroundStyle(.tint).font(.title3)
        }
        .contentShape(Rectangle())
    }

    private func load() {
        task?.cancel()
        loading = true
        error = nil
        results = []
        let selected = category
        task = Task {
            do {
                let found = try await model.searchAlongRoute(selected)
                guard !Task.isCancelled, selected == category else { return }
                // Bei Tankstellen mit Preis: günstigste zuerst, wenn so eingestellt.
                if selected == .fuel, settings.fuelSortByPrice, found.contains(where: { $0.price != nil }) {
                    results = found.sorted { ($0.price ?? .infinity, $0.alongMeters) < ($1.price ?? .infinity, $1.alongMeters) }
                } else {
                    results = found
                }
            } catch AppError.offlineMode {
                if !Task.isCancelled { error = String(localized: "Braucht Internet (Offline-Modus ist an).") }
            } catch {
                if !Task.isCancelled { self.error = String(localized: "Suche fehlgeschlagen (Server überlastet?).") }
            }
            if !Task.isCancelled { loading = false }
        }
    }
}
