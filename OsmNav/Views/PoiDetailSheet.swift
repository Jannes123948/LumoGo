import SwiftUI

/** Detail-Blatt für einen angetippten Ort: Kategorie, Öffnungszeiten, Adresse, Aktionen. */
struct PoiDetailSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var showWeek = false

    var body: some View {
        if let selection = model.poiSelection {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(selection)
                    actions(selection)
                    Divider()
                    content(selection)
                }
                .padding(20)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func header(_ selection: AppModel.PoiSelection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.name).font(.title2.bold())
            let distance = model.currentPosition.map { FormatUtils.formatDistance(GeoUtils.distanceMeters($0, selection.point)) }
            let subtitle = [selection.details?.category, distance].compactMap { $0 }.joined(separator: " · ")
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            if let hours = selection.details?.openingHours {
                let status = hours.status()
                Text(status.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.changesSoon ? .orange : (status.isOpen ? .green : .red))
            }
        }
    }

    private func actions(_ selection: AppModel.PoiSelection) -> some View {
        HStack(spacing: 10) {
            Button {
                model.routeToPoi(selection)
            } label: {
                Label("Route", systemImage: "arrow.triangle.turn.up.right.diamond.fill").frame(maxWidth: .infinity)
            }
            .adaptiveButtonStyle(prominent: true)

            Button {
                model.savePoiAsFavorite(selection)
            } label: {
                Image(systemName: "star")
            }
            .adaptiveButtonStyle(prominent: false)

            if let phone = selection.details?.phone,
               let url = URL(string: "tel:" + phone.filter { $0.isNumber || $0 == "+" }) {
                Button { openURL(url) } label: { Image(systemName: "phone.fill") }
                    .adaptiveButtonStyle(prominent: false)
            }
            if let website = selection.details?.website {
                Button { openURL(website) } label: { Image(systemName: "safari") }
                    .adaptiveButtonStyle(prominent: false)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private func content(_ selection: AppModel.PoiSelection) -> some View {
        if selection.loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Infos werden geladen …").foregroundStyle(.secondary)
            }
        } else if selection.failed {
            VStack(alignment: .leading, spacing: 8) {
                Text("Infos konnten nicht geladen werden – der OpenStreetMap-Server ist gerade ausgelastet.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Erneut versuchen") { model.loadPoiDetails() }
            }
        } else if let details = selection.details {
            openingHoursSection(details)
            if let address = details.address {
                Label(address, systemImage: "mappin.and.ellipse").font(.subheadline)
            }
            if let phone = details.phone {
                Label(phone, systemImage: "phone").font(.subheadline)
            }
            if let website = details.website {
                Label(website.host ?? website.absoluteString, systemImage: "globe").font(.subheadline).lineLimit(1)
            }
        } else {
            Text("Keine weiteren Infos in OpenStreetMap eingetragen.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func openingHoursSection(_ details: PoiDetails) -> some View {
        if let hours = details.openingHours {
            DisclosureGroup(isExpanded: $showWeek) {
                let today = OpeningHours.dayIndex(Date())
                VStack(spacing: 6) {
                    ForEach(Array(hours.weeklyLines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top) {
                            Text(line.day).frame(width: 34, alignment: .leading)
                            Text(line.hours).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.subheadline.weight(index == today ? .semibold : .regular))
                    }
                }
                .padding(.top, 6)
            } label: {
                Label("Öffnungszeiten", systemImage: "clock").font(.subheadline)
            }
        } else if let raw = details.openingHoursRaw {
            // Zu komplex für den eingebauten Parser (Monate, Feiertage, …) → Rohtext.
            Label(raw.replacingOccurrences(of: "; ", with: "\n"), systemImage: "clock").font(.subheadline)
        } else {
            Label("Keine Öffnungszeiten eingetragen", systemImage: "clock")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}
