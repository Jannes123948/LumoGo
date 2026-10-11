import SwiftUI

/** „Ankommen um …“: gewünschte Ankunft → Losfahrzeit, Erinnerung; Termine mit Ort aus dem Kalender. */
struct ArrivalPlannerSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var arrival = Date()
    @State private var pending: Date?

    private var duration: Double { model.lastRoute?.duration ?? 0 }
    private var departure: Date {
        DeparturePlanner.departure(arrival: arrival, durationSeconds: duration, bufferMinutes: settings.departureBuffer)
    }
    private var destinationName: String {
        model.waypoints.last.map { $0.label.components(separatedBy: ",").first ?? $0.label } ?? String(localized: "Ziel")
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.lastRoute != nil {
                    Section {
                        Label(destinationName, systemImage: "mappin.circle.fill")
                            .font(.headline)
                        DatePicker("Ankunft", selection: $arrival, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        Stepper(value: $settings.departureBuffer, in: 0...90, step: 5) {
                            SettingsRow(title: "Puffer", symbol: "hourglass", color: .orange,
                                        value: String(localized: "\(settings.departureBuffer) Min."))
                        }
                    } footer: {
                        Text("Fahrzeit laut Route \(FormatUtils.formatDuration(duration)) — ohne aktuelle Verkehrslage, deshalb der Puffer.")
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Losfahren um").font(.subheadline).foregroundStyle(.secondary)
                            Text(departure.formatted(date: Calendar.current.isDateInToday(departure) ? .omitted : .abbreviated, time: .shortened))
                                .font(.system(size: 34, weight: .bold))
                                .monospacedDigit()
                            if departure < Date() {
                                Text("Das ist schon vorbei — bei sofortiger Abfahrt Ankunft gegen \(Date().addingTimeInterval(duration).formatted(date: .omitted, time: .shortened)).")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.vertical, 4)
                        Button {
                            model.scheduleDeparture(arrival: arrival)
                            Task {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                pending = await DeparturePlanner.pendingReminder()
                            }
                        } label: {
                            Label("Zur Losfahrzeit erinnern", systemImage: "bell.badge.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .adaptiveButtonStyle(prominent: true)
                        .disabled(departure < Date())
                        if let pending {
                            HStack {
                                Label("Erinnerung um \(pending.formatted(date: .omitted, time: .shortened))", systemImage: "bell.fill")
                                    .font(.subheadline)
                                Spacer()
                                Button("Löschen", role: .destructive) {
                                    DeparturePlanner.cancelReminder()
                                    self.pending = nil
                                }
                                .font(.subheadline)
                            }
                        }
                    } footer: {
                        Text("Tippen auf die Mitteilung startet direkt die Navigation.")
                    }
                }

                if settings.calendarTrips {
                    CalendarTripsSection()
                }
            }
            .navigationTitle("Ankommen um …")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task {
                // Vorgabe: Termin bzw. jetzt + Fahrzeit + Puffer, auf 5 Minuten aufgerundet.
                let base = model.plannedArrival ?? Date().addingTimeInterval(duration + Double(settings.departureBuffer + 15) * 60)
                let minutes = (base.timeIntervalSinceReferenceDate / 300).rounded(.up) * 300
                arrival = model.plannedArrival ?? Date(timeIntervalSinceReferenceDate: minutes)
                model.plannedArrival = nil
                pending = await DeparturePlanner.pendingReminder()
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/** Termine der nächsten 48 Stunden mit Ort — Tippen setzt das Ziel und plant die Ankunft zum Terminbeginn. */
struct CalendarTripsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var trips: [CalendarTrip] = []
    @State private var access = DeparturePlanner.hasCalendarAccess

    var body: some View {
        Section {
            if !access {
                Button {
                    Task {
                        access = await DeparturePlanner.requestCalendarAccess()
                        trips = DeparturePlanner.upcomingTrips()
                    }
                } label: {
                    Label("Kalender-Termine anzeigen", systemImage: "calendar")
                }
            } else if trips.isEmpty {
                Text("Keine Termine mit Ort in den nächsten 48 Stunden.").foregroundStyle(.secondary)
            }
            ForEach(trips) { trip in
                Button {
                    model.planTrip(trip)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trip.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(trip.start.formatted(date: Calendar.current.isDateInToday(trip.start) ? .omitted : .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(trip.location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        } header: {
            Text("Aus dem Kalender")
        } footer: {
            Text("Termine mit Ort: Tippen setzt das Ziel und plant die Ankunft zum Terminbeginn.")
        }
        .task { if access { trips = DeparturePlanner.upcomingTrips() } }
    }
}
