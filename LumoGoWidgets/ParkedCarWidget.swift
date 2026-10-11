import SwiftUI
import WidgetKit

/** Widget „Mein Auto“: wo das Auto steht und seit wann, mit „Hinführen“ (Homescreen + Sperrbildschirm). */
struct ParkedCarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ParkedCarShared.widgetKind, provider: ParkedCarProvider()) { entry in
            ParkedCarView(car: entry.car)
        }
        .configurationDisplayName("Mein Auto")
        .description("Zeigt, wo dein Auto geparkt ist — mit einem Tipp zu Fuß hinführen.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct ParkedCarEntry: TimelineEntry {
    let date: Date
    let car: ParkedCarSnapshot?
}

struct ParkedCarProvider: TimelineProvider {
    func placeholder(in context: Context) -> ParkedCarEntry {
        ParkedCarEntry(date: Date(), car: ParkedCarSnapshot(latitude: 0, longitude: 0, date: Date().addingTimeInterval(-3600),
                                                            address: String(localized: "Bautzner Straße 12, Dresden")))
    }

    func getSnapshot(in context: Context, completion: @escaping (ParkedCarEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : ParkedCarEntry(date: Date(), car: ParkedCarShared.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ParkedCarEntry>) -> Void) {
        // Die App lädt das Widget bei jeder Änderung neu; „seit …“ zählt das System selbst hoch.
        completion(Timeline(entries: [ParkedCarEntry(date: Date(), car: ParkedCarShared.load())], policy: .never))
    }
}

private struct ParkedCarView: View {
    let car: ParkedCarSnapshot?
    @Environment(\.widgetFamily) private var family

    private static let blue = Color(red: 0.08, green: 0.4, blue: 0.85)

    var body: some View {
        switch family {
        case .accessoryRectangular:
            HStack(spacing: 8) {
                Image(systemName: "car.fill").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    if let car {
                        Text(car.address ?? String(localized: "Mein Auto")).font(.headline).lineLimit(2)
                        Text(car.date, style: .relative).font(.caption)
                    } else {
                        Text("Kein Parkplatz gemerkt").font(.headline)
                    }
                }
            }
            .widgetURL(DeepLink.car.url)
            .carWidgetBackground(Color.clear)
        case .systemMedium:
            HStack(spacing: 12) {
                info.frame(maxWidth: .infinity, alignment: .leading)
                if car != nil {
                    VStack(spacing: 8) {
                        CarButton(title: String(localized: "Hinführen"), symbol: "figure.walk", link: .walkToCar, prominent: true)
                        CarButton(title: String(localized: "Anzeigen"), symbol: "map.fill", link: .car)
                    }
                    .frame(width: 118)
                }
            }
            .padding(14)
            .carWidgetBackground(LinearGradient(colors: [Brand.top, Brand.bottom], startPoint: .top, endPoint: .bottom))
        default:
            info
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(14)
                .widgetURL(car == nil ? DeepLink.open.url : DeepLink.car.url)
                .carWidgetBackground(LinearGradient(colors: [Brand.top, Brand.bottom], startPoint: .top, endPoint: .bottom))
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "car.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Self.blue, in: Circle())
            Spacer(minLength: 0)
            if let car {
                Text(car.address ?? String(localized: "Mein Auto"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let note = car.note {
                    Text(note).font(.caption).foregroundStyle(Brand.glow).lineLimit(1)
                }
                (Text("seit ") + Text(car.date, style: .relative))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            } else {
                Text("Kein Parkplatz gemerkt").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text("Wird bei Ankunft mit dem Auto gemerkt.").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

private struct CarButton: View {
    let title: String
    let symbol: String
    let link: DeepLink
    var prominent = false

    var body: some View {
        Link(destination: link.url) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(prominent ? Brand.bottom : .white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(prominent ? Brand.glow : Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

private extension View {
    /** Ab iOS 17 verlangt WidgetKit `containerBackground`. */
    @ViewBuilder
    func carWidgetBackground<S: ShapeStyle>(_ style: S) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            containerBackground(style, for: .widget)
        } else {
            background(style)
        }
    }
}
