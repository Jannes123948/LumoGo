import AppIntents

/**
 * Siri + Kurzbefehle-App (App Intents, ab iOS 16): „Mit LumoGo nach Hause“, „Navigiere mit LumoGo zu
 * <Favorit>“, Tankstellen, Suche. Alle öffnen die App (`openAppWhenRun`) und laufen in ihrem Prozess —
 * deshalb direkt über [AppModel.current]. Erscheinen automatisch in Siri/Spotlight/Kurzbefehle,
 * es gibt nichts einzurichten.
 */
struct NavigateHomeIntent: AppIntent {
    static var title: LocalizedStringResource = "Nach Hause navigieren"
    static var description = IntentDescription("Berechnet die Route zum gespeicherten Zuhause und startet die Navigation.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.current?.handle(.home)
        return .result()
    }
}

struct NavigateToFavoriteIntent: AppIntent {
    static var title: LocalizedStringResource = "Zu Favorit navigieren"
    static var description = IntentDescription("Startet die Navigation zu einem gespeicherten Favoriten.")
    static var openAppWhenRun = true

    @Parameter(title: "Favorit")
    var favorite: FavoriteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Navigiere zu \(\.$favorite)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.current?.handle(.favorite(id: favorite.id))
        return .result()
    }
}

struct FindFuelIntent: AppIntent {
    static var title: LocalizedStringResource = "Tankstellen in der Nähe"
    static var description = IntentDescription("Zeigt Tankstellen in der Nähe — mit Spritpreisen, wenn ein Tankerkönig-Schlüssel eingetragen ist.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.current?.handle(.nearbyFuel)
        return .result()
    }
}

struct OpenSearchIntent: AppIntent {
    static var title: LocalizedStringResource = "Ort suchen"
    static var description = IntentDescription("Öffnet LumoGo mit der Suchleiste.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.current?.handle(.search)
        return .result()
    }
}

/** Ein Favorit als Auswahl für Siri/Kurzbefehle (gelesen aus [FavoritesStore]). */
struct FavoriteEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Favorit"
    static var defaultQuery = FavoriteQuery()

    let id: String
    let name: String
    let isHome: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: isHome ? "house.fill" : "star.fill"))
    }

    init(_ favorite: Favorite) {
        id = favorite.id
        name = favorite.name
        isHome = favorite.isHome
    }
}

struct FavoriteQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [FavoriteEntity] {
        FavoritesStore.list().filter { identifiers.contains($0.id) }.map(FavoriteEntity.init)
    }

    func entities(matching string: String) async throws -> [FavoriteEntity] {
        FavoritesStore.list().filter { $0.name.localizedCaseInsensitiveContains(string) }.map(FavoriteEntity.init)
    }

    func suggestedEntities() async throws -> [FavoriteEntity] {
        FavoritesStore.list().map(FavoriteEntity.init)
    }
}

struct LumoGoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NavigateHomeIntent(),
            phrases: [
                "Mit \(.applicationName) nach Hause",
                "Navigiere mit \(.applicationName) nach Hause",
                "\(.applicationName) nach Hause"
            ],
            shortTitle: "Nach Hause",
            systemImageName: "house.fill"
        )
        AppShortcut(
            intent: NavigateToFavoriteIntent(),
            phrases: [
                "Navigiere mit \(.applicationName) zu \(\.$favorite)",
                "Mit \(.applicationName) zu \(\.$favorite)"
            ],
            shortTitle: "Zu Favorit",
            systemImageName: "star.fill"
        )
        AppShortcut(
            intent: FindFuelIntent(),
            phrases: [
                "Tankstellen in der Nähe mit \(.applicationName)",
                "Wo kann ich tanken mit \(.applicationName)"
            ],
            shortTitle: "Tankstellen",
            systemImageName: "fuelpump.fill"
        )
        AppShortcut(
            intent: OpenSearchIntent(),
            phrases: ["Suche in \(.applicationName)", "\(.applicationName) Suche"],
            shortTitle: "Suchen",
            systemImageName: "magnifyingglass"
        )
    }
}
