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

/** „Wann komme ich an?“ — Siri antwortet mit Ankunftszeit und Reststrecke, ohne die App zu öffnen. */
struct NavigationStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Wann komme ich an?"
    static var description = IntentDescription("Sagt Ankunftszeit und Reststrecke der laufenden Navigation.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = AppModel.current?.navigationStatusSentence() ?? String(localized: "Gerade läuft keine Navigation.")
        return .result(dialog: "\(text)")
    }
}

/** „Wo ist mein Auto?“ — Adresse und Parkzeit (und Entfernung, wenn die App den Standort kennt). */
struct WhereIsMyCarIntent: AppIntent {
    static var title: LocalizedStringResource = "Wo ist mein Auto?"
    static var description = IntentDescription("Sagt, wo das Auto geparkt ist.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(ParkingStore.spokenLocation(from: AppModel.current?.currentPosition))")
    }
}

/** „Bring mich zum Auto“ — öffnet die App und startet die Fußnavigation zum Parkplatz. */
struct WalkToCarIntent: AppIntent {
    static var title: LocalizedStringResource = "Zum Auto navigieren"
    static var description = IntentDescription("Startet die Fußnavigation zum geparkten Auto.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppModel.current?.handle(.walkToCar)
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
            // Siri vergleicht fast wörtlich — „Zuhause“ statt „nach Hause“ passte vorher nicht
            // (Nutzermeldung: „LumoGo unterstützt das nicht“). Deshalb viele Varianten.
            phrases: [
                "Mit \(.applicationName) nach Hause",
                "Mit \(.applicationName) nach Zuhause",
                "Mit \(.applicationName) zuhause",
                "Mit \(.applicationName) heim",
                "Navigiere mit \(.applicationName) nach Hause",
                "Navigiere mit \(.applicationName) nach Zuhause",
                "Navigiere mit \(.applicationName) zu mir nach Hause",
                "Fahr mich mit \(.applicationName) nach Hause",
                "Bring mich mit \(.applicationName) nach Hause",
                "\(.applicationName) nach Hause",
                "\(.applicationName) Zuhause",
                "\(.applicationName) heim",
                "\(.applicationName) navigiere nach Hause",
                "\(.applicationName) bring mich nach Hause",
                "Nach Hause mit \(.applicationName)",
                "Zuhause mit \(.applicationName)",
                "Heimweg mit \(.applicationName)"
            ],
            shortTitle: "Nach Hause",
            systemImageName: "house.fill"
        )
        AppShortcut(
            intent: NavigateToFavoriteIntent(),
            phrases: [
                "Navigiere mit \(.applicationName) zu \(\.$favorite)",
                "Mit \(.applicationName) zu \(\.$favorite)",
                "Mit \(.applicationName) nach \(\.$favorite)",
                "Fahr mich mit \(.applicationName) zu \(\.$favorite)",
                "Bring mich mit \(.applicationName) zu \(\.$favorite)",
                "\(.applicationName) navigiere zu \(\.$favorite)",
                "\(.applicationName) zu \(\.$favorite)",
                "\(.applicationName) \(\.$favorite)"
            ],
            shortTitle: "Zu Favorit",
            systemImageName: "star.fill"
        )
        AppShortcut(
            intent: FindFuelIntent(),
            phrases: [
                "Tankstellen in der Nähe mit \(.applicationName)",
                "Wo kann ich tanken mit \(.applicationName)",
                "\(.applicationName) Tankstellen",
                "\(.applicationName) tanken",
                "\(.applicationName) Spritpreise",
                "Spritpreise mit \(.applicationName)"
            ],
            shortTitle: "Tankstellen",
            systemImageName: "fuelpump.fill"
        )
        AppShortcut(
            intent: OpenSearchIntent(),
            phrases: ["Suche in \(.applicationName)", "Suche mit \(.applicationName)", "\(.applicationName) Suche", "\(.applicationName) suchen"],
            shortTitle: "Suchen",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: NavigationStatusIntent(),
            phrases: [
                "Wann komme ich mit \(.applicationName) an",
                "\(.applicationName) Ankunftszeit",
                "Wie lange noch mit \(.applicationName)",
                "Wie weit ist es noch mit \(.applicationName)",
                "\(.applicationName) wie lange noch"
            ],
            shortTitle: "Ankunftszeit",
            systemImageName: "clock.fill"
        )
        AppShortcut(
            intent: WhereIsMyCarIntent(),
            phrases: [
                "Wo ist mein Auto mit \(.applicationName)",
                "\(.applicationName) wo ist mein Auto",
                "Wo habe ich mit \(.applicationName) geparkt",
                "\(.applicationName) mein Auto"
            ],
            shortTitle: "Mein Auto",
            systemImageName: "car.fill"
        )
        AppShortcut(
            intent: WalkToCarIntent(),
            phrases: [
                "Bring mich mit \(.applicationName) zum Auto",
                "\(.applicationName) zum Auto",
                "Zu meinem Auto mit \(.applicationName)"
            ],
            shortTitle: "Zum Auto",
            systemImageName: "figure.walk"
        )
    }
}
