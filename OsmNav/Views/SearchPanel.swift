import SwiftUI

/** Suchleiste mit Live-Vorschlägen/Suchverlauf und der Liste der gesetzten Ziele. */
struct SearchPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var offline = OfflineMapsManager.shared
    @FocusState private var focused: Bool
    /** Tipp auf die Prozentanzeige öffnet die Offline-Karten. */
    var onOpenDownloads: () -> Void = {}

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                // Nur während eines Downloads (Kartenpaket, Suchdaten, Straßennetz).
                if let fraction = offline.activeDownloadFraction {
                    Button(action: onOpenDownloads) {
                        DownloadProgressRing(fraction: fraction)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(offline.activeDownloadLabel)-Download \(Int(fraction * 100)) Prozent")
                    .transition(.move(edge: .leading).combined(with: .opacity))
                }
                searchBar
            }
            .animation(.easeInOut(duration: 0.25), value: offline.activeDownloadFraction == nil)

            if model.showSearchResults {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.searchResults) { result in
                            HStack {
                                Button {
                                    model.selectSearchResult(result)
                                } label: {
                                    Text(result.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Button {
                                    model.saveSearchResultAsFavorite(result)
                                } label: {
                                    Image(systemName: "star")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            Divider()
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .frame(maxHeight: 280)
                .card()
            } else if !model.waypoints.isEmpty {
                WaypointsCard()
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            if model.searching {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            }
            TextField("Adresse oder Ort suchen", text: $model.searchText)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { model.submitSearch() }
            if !model.searchText.isEmpty {
                Button { model.clearSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .card()
        .onChange(of: focused) { model.searchFocused = $0 }
        .onChange(of: model.searchFocused) { if !$0 { focused = false } }
    }
}

/** Ziele/Zwischenstopps — per Ziehgriff umsortierbar, einzeln oder alle löschbar. */
struct WaypointsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.waypoints.count == 1 ? "1 Ziel gesetzt" : "\(model.waypoints.count) Ziele gesetzt")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Ziele löschen", role: .destructive) { model.clearDestinations() }
                    .font(.subheadline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            List {
                ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    HStack(spacing: 10) {
                        Image(systemName: index == model.waypoints.count - 1 ? "mappin.circle.fill" : "circle.fill")
                            .foregroundStyle(index == model.waypoints.count - 1 ? .red : .orange)
                            .font(index == model.waypoints.count - 1 ? .body : .caption)
                        Text(waypoint.label).font(.subheadline).lineLimit(1)
                    }
                }
                .onMove { model.moveWaypoints(from: $0, to: $1) }
                .onDelete { model.removeWaypoints(at: $0) }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .frame(height: min(CGFloat(model.waypoints.count) * 44, 160))
        }
        .card()
    }
}

/** Kreis-Fortschritt mit Prozentzahl in der Oberflächenfarbe (links neben der Suchleiste). */
private struct DownloadProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: fraction)
            Text("\(Int((fraction * 100).rounded(.down)))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
        }
        .padding(7)
        .frame(width: 48, height: 48)
        .card()
    }
}
