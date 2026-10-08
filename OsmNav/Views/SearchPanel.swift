import SwiftUI

/** Suchleiste mit Live-Vorschlägen/Suchverlauf und der Liste der gesetzten Ziele. */
struct SearchPanel: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
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
