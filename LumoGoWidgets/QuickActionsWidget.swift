import SwiftUI
import WidgetKit

/** Schnellzugriff (Homescreen + Sperrbildschirm): Nach Hause, Favoriten, Suche, Tankstellen. Feste
 *  Inhalte — die Erweiterung kennt die Favoriten nicht, die App löst den Link auf. */
struct QuickActionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LumoGoQuickActions", provider: QuickProvider()) { _ in
            QuickActionsView()
        }
        .configurationDisplayName("LumoGo")
        .description("Mit einem Tipp nach Hause navigieren, Favoriten öffnen oder suchen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct QuickEntry: TimelineEntry {
    let date: Date
}

struct QuickProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickEntry { QuickEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (QuickEntry) -> Void) { completion(QuickEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickEntry>) -> Void) {
        completion(Timeline(entries: [QuickEntry(date: Date())], policy: .never))
    }
}

private struct QuickActionsView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "house.fill").font(.title2)
            }
            .widgetURL(DeepLink.home.url)
            .widgetBackground(Color.clear)
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "house.fill").font(.title2)
                VStack(alignment: .leading) {
                    Text("Nach Hause").font(.headline)
                    Text("LumoGo").font(.caption)
                }
            }
            .widgetURL(DeepLink.home.url)
            .widgetBackground(Color.clear)
        case .systemMedium:
            HStack(spacing: 10) {
                QuickTile(title: "Nach Hause", symbol: "house.fill", link: .home, prominent: true)
                VStack(spacing: 10) {
                    QuickTile(title: "Favoriten", symbol: "star.fill", link: .favorites)
                    QuickTile(title: "Suchen", symbol: "magnifyingglass", link: .search)
                }
                VStack(spacing: 10) {
                    QuickTile(title: "Tanken", symbol: "fuelpump.fill", link: .nearbyFuel)
                    QuickTile(title: "Karte", symbol: "map.fill", link: .open)
                }
            }
            .padding(12)
            .widgetBackground(LinearGradient(colors: [Brand.top, Brand.bottom], startPoint: .top, endPoint: .bottom))
        default:
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "house.fill").font(.system(size: 30, weight: .bold)).foregroundStyle(Brand.glow)
                Spacer(minLength: 0)
                Text("Nach Hause").font(.headline).foregroundStyle(.white)
                Text("LumoGo").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(14)
            .widgetURL(DeepLink.home.url)
            .widgetBackground(LinearGradient(colors: [Brand.top, Brand.bottom], startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct QuickTile: View {
    let title: String
    let symbol: String
    let link: DeepLink
    var prominent = false

    var body: some View {
        Link(destination: link.url) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: prominent ? 26 : 16, weight: .bold))
                Text(title).font(prominent ? .subheadline.weight(.semibold) : .caption2.weight(.semibold)).lineLimit(1)
            }
            .foregroundStyle(prominent ? Brand.bottom : .white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(prominent ? Brand.glow : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

private extension View {
    /** Ab iOS 17 verlangt WidgetKit `containerBackground`, sonst zeigt das System einen Hinweis statt des Widgets. */
    @ViewBuilder
    func widgetBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(style, for: .widget)
        } else {
            background(style)
        }
    }
}
