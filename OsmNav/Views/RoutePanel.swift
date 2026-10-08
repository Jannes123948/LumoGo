import SwiftUI
import Charts

/** Unteres Panel vor Navigationsstart: Profil, Alternativrouten, Höhenprofil, Anweisungen, Buttons. */
struct RoutePanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Profil", selection: $settings.routingProfile) {
                ForEach(RoutingProfile.allCases) { profile in
                    Label(profile.label, systemImage: profile.symbol).tag(profile)
                }
            }
            .pickerStyle(.segmented)

            if model.routeOptions.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.routeOptions.enumerated()), id: \.element.id) { index, route in
                            let selected = index == model.selectedRouteIndex
                            Button { model.selectRoute(index) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(FormatUtils.formatDuration(route.duration)).font(.headline)
                                    Text(FormatUtils.formatDistance(route.distance)).font(.caption)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(selected ? Color.accentColor : Color(.secondarySystemBackground),
                                            in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            } else if let route = model.lastRoute {
                Text("\(FormatUtils.formatDuration(route.duration)) · \(FormatUtils.formatDistance(route.distance))")
                    .font(.headline)
            }

            if settings.routePreviewEnabled, model.lastRoute != nil {
                if let profile = model.elevationProfile {
                    ElevationChart(profile: profile)
                }
                Button(model.showInstructions ? "Anweisungen ausblenden" : "Anweisungen anzeigen") {
                    model.showInstructions.toggle()
                }
                .font(.subheadline)
                if model.showInstructions {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.instructions.enumerated()), id: \.offset) { index, text in
                                Text("\(index + 1). \(text)").font(.footnote)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.calculateRoute()
                } label: {
                    HStack {
                        if model.routeLoading { ProgressView().tint(.white) }
                        Text("Route berechnen")
                    }
                    .frame(maxWidth: .infinity)
                }
                .adaptiveButtonStyle(prominent: true)
                .disabled(model.routeLoading)

                Button {
                    model.startNavigation()
                } label: {
                    Label("Starten", systemImage: "location.north.line.fill").frame(maxWidth: .infinity)
                }
                .adaptiveButtonStyle(prominent: true)
                .disabled(model.lastRoute == nil)
            }
            .controlSize(.large)
        }
        .padding(14)
        .card()
    }
}

/** Mini-Höhenprofil mit Gesamtanstieg/-abstieg (Swift Charts statt selbst gezeichnetem Canvas). */
struct ElevationChart: View {
    let profile: ElevationProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Anstieg \(FormatUtils.formatDistance(profile.ascentMeters)) ↑ · Abstieg \(FormatUtils.formatDistance(profile.descentMeters)) ↓")
                .font(.caption)
                .foregroundStyle(.secondary)
            let minElevation = profile.points.map(\.elevationMeters).min() ?? 0
            Chart(profile.points) { point in
                AreaMark(
                    x: .value("Distanz", point.distanceMeters / 1000),
                    yStart: .value("Basis", minElevation - 5),
                    yEnd: .value("Höhe", point.elevationMeters)
                )
                .foregroundStyle(Color.accentColor.opacity(0.3))
                LineMark(x: .value("Distanz", point.distanceMeters / 1000), y: .value("Höhe", point.elevationMeters))
                    .foregroundStyle(Color.accentColor)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis(.hidden)
            .frame(height: 56)
        }
    }
}
