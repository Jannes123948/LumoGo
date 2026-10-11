import SwiftUI

/** Runde Plakette eines Favoriten (Symbol in seiner Farbe) — wie auf der Karte. */
struct FavoriteBadge: View {
    let symbol: String
    let colorHex: Int
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: UInt32(colorHex)), in: Circle())
    }
}

/** Symbol, Farbe und Gruppe eines Favoriten — beim Speichern und Bearbeiten. */
struct FavoriteStyleFields: View {
    @Binding var symbol: String
    @Binding var colorHex: Int
    @Binding var group: String
    private let groups = FavoritesStore.groups()

    var body: some View {
        Section("Symbol") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 10) {
                ForEach(FavoriteStyle.symbols, id: \.self) { name in
                    Button { symbol = name } label: {
                        FavoriteBadge(symbol: name, colorHex: name == symbol ? colorHex : 0x9E9E9E, size: 38)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: name == symbol ? 2.5 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding(.vertical, 6)
        }
        Section("Farbe") {
            HStack(spacing: 10) {
                ForEach(FavoriteStyle.colors, id: \.self) { hex in
                    Button { colorHex = hex } label: {
                        Circle()
                            .fill(Color(hex: UInt32(hex)))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: hex == colorHex ? 2.5 : 0).padding(-3))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        Section {
            TextField("Gruppe (z. B. Arbeit, Familie)", text: $group)
            if !groups.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(groups, id: \.self) { name in
                            Button(name) { group = name }
                                .buttonStyle(.bordered)
                                .font(.footnote)
                        }
                    }
                }
            }
        } header: {
            Text("Gruppe")
        } footer: {
            Text("Favoriten mit derselben Gruppe stehen in der Liste zusammen.")
        }
    }
}

/** Favorit bearbeiten: Name, Symbol, Farbe, Gruppe. */
struct FavoriteEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let favorite: Favorite
    @State private var name = ""
    @State private var symbol = "star.fill"
    @State private var colorHex = 0xF57C00
    @State private var group = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        FavoriteBadge(symbol: symbol, colorHex: colorHex, size: 40)
                        TextField("Name", text: $name)
                    }
                }
                FavoriteStyleFields(symbol: $symbol, colorHex: $colorHex, group: $group)
            }
            .navigationTitle("Favorit bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        var updated = favorite
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty { updated.name = trimmed }
                        updated.symbol = symbol
                        updated.colorHex = colorHex
                        updated.group = group.trimmingCharacters(in: .whitespaces)
                        FavoritesStore.update(updated)
                        dismiss()
                    }
                }
            }
            .onAppear {
                name = favorite.name
                symbol = favorite.displaySymbol
                colorHex = favorite.displayColorHex
                group = favorite.groupName ?? ""
            }
        }
    }
}
