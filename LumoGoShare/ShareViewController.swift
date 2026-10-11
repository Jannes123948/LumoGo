import UIKit
import SwiftUI
import UniformTypeIdentifiers
// Nur verlinkt, damit Xcodes App-Intents-Metadaten-Schritt nicht „Metadata extraction skipped“ meldet.
import AppIntents

/**
 * Teilen-Erweiterung „LumoGo“: nimmt Karten-Links/Texte aus anderen Apps an, erkennt den Ort
 * ([SharedLinkParser]), legt ihn im gemeinsamen Container ab ([SharedPlaceInbox]) und öffnet LumoGo.
 */
final class ShareViewController: UIViewController {

    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        // Sprache der App übernehmen (wirkt beim nächsten Start der Erweiterung).
        AppLanguage.syncFromAppGroup()
        let host = UIHostingController(rootView: ShareCard(state: state, onOpen: { [weak self] in self?.openInApp() },
                                                          onCancel: { [weak self] in self?.finish() }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        Task { await loadPlace() }
    }

    @MainActor
    private func loadPlace() async {
        var urls: [URL] = []
        var texts: [String] = []
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) {
                if let url = item as? URL { urls.append(url) }
                else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { urls.append(url) }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.vCard.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.vCard.identifier) {
                // Visitenkarten (Apple Karten/Kontakte) enthalten den Karten-Link als Text.
                if let data = item as? Data, let text = String(data: data, encoding: .utf8) { texts.append(Self.vCardText(text)) }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let item = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) {
                if let text = item as? String { texts.append(text) }
                else if let data = item as? Data, let text = String(data: data, encoding: .utf8) { texts.append(text) }
            }
        }
        // Kurzlinks (maps.app.goo.gl, maps.apple/p/…) vorher auflösen.
        var resolved: [URL] = []
        for url in urls {
            resolved.append(SharedLinkParser.needsResolving(url) ? await SharedLinkParser.resolve(url) : url)
        }
        state.place = SharedLinkParser.place(urls: resolved, texts: texts)
        state.loading = false
    }

    /** Aus einer vCard Name, Adresse und Links ziehen (der Rest stört die Suche). */
    private static func vCardText(_ card: String) -> String {
        var name: String?
        var lines: [String] = []
        for raw in card.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].uppercased()
            let value = String(line[line.index(after: colon)...]).replacingOccurrences(of: "\\,", with: ",")
            if key.hasPrefix("FN") { name = value }
            else if key.contains("URL") { lines.append(value.replacingOccurrences(of: "\\:", with: ":")) }
            else if key.contains("ADR") {
                let parts = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                lines.append(parts.joined(separator: ", "))
            }
        }
        return ([name].compactMap { $0 } + lines).joined(separator: "\n")
    }

    private func openInApp() {
        guard let place = state.place else { return }
        guard SharedPlaceInbox.put(place) else {
            state.error = String(localized: "LumoGo konnte den Ort nicht übernehmen — beim Signieren fehlt die App Group „\(NavWidgetStore.appGroup)“ für die Erweiterung.")
            return
        }
        if !openURL(DeepLink.shared.url) {
            state.opened = true // App selbst öffnen — der Ort wartet dort.
            return
        }
        finish()
    }

    /**
     * Erweiterungen dürfen `UIApplication.shared` nicht benutzen — über die Responder-Kette kommt man
     * trotzdem an die Anwendung und ruft `openURL:options:completionHandler:` dynamisch auf.
     */
    private func openURL(_ url: URL) -> Bool {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        while let current = responder {
            if current is UIApplication, current.responds(to: selector) {
                typealias OpenFunction = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let function = unsafeBitCast(current.method(for: selector), to: OpenFunction.self)
                function(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
final class ShareState: ObservableObject {
    @Published var loading = true
    @Published var place: SharedPlace?
    @Published var error: String?
    /** Öffnen ging nicht automatisch — Hinweis, LumoGo selbst zu öffnen. */
    @Published var opened = false
}

private struct ShareCard: View {
    @ObservedObject var state: ShareState
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("LumoGo", systemImage: "location.north.fill")
                        .font(.headline)
                    Spacer()
                    Button("Abbrechen", action: onCancel)
                }
                if state.loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Ort wird erkannt …").foregroundStyle(.secondary)
                    }
                } else if let place = state.place {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: place.hasCoordinate ? "mappin.circle.fill" : "magnifyingglass.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.displayName).font(.title3.weight(.semibold)).lineLimit(3)
                            if let lat = place.latitude, let lon = place.longitude {
                                Text(String(format: "%.5f, %.5f", lat, lon)).font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Text("Wird in LumoGo gesucht").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let error = state.error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    } else if state.opened {
                        Text("Gespeichert — öffne jetzt LumoGo, der Ort wird dort übernommen.")
                            .font(.footnote)
                        Button("Fertig", action: onCancel)
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    } else {
                        Button(action: onOpen) {
                            Label(place.hasCoordinate ? "Als Ziel in LumoGo" : "In LumoGo suchen", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("Hier ist kein Ort erkennbar. Geteilt werden können Links aus Apple Karten, Google Maps und OpenStreetMap, Koordinaten oder Adressen.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(12)
        }
        .background(Color.black.opacity(0.25).ignoresSafeArea())
    }
}
