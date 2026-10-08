import SwiftUI
import MapLibre

/** Eine Fahrt aus dem Fahrtenbuch: Strecke auf der Karte, Werte, GPX-Export. */
struct TripDetailView: View {
    let trip: Trip
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var points: [TrackPoint] = []
    @State private var gpxFile: URL?

    var body: some View {
        List {
            if points.count >= 2 {
                Section {
                    TripMapView(points: points, dark: colorScheme == .dark, lineHex: settings.routeHex)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                }
            }
            Section {
                row("Ziel", trip.destinationName)
                row("Datum", trip.timestamp.formatted(date: .complete, time: .shortened))
                row("Dauer", FormatUtils.formatDuration(trip.durationSeconds))
                row("Gefahren", FormatUtils.formatDistance(trip.drivenMeters ?? trip.distanceMeters))
                if trip.drivenMeters != nil {
                    row("Geplant", FormatUtils.formatDistance(trip.distanceMeters))
                }
                if let avg = trip.averageKmh { row("Ø Geschwindigkeit", "\(Int(avg.rounded())) km/h") }
                if let max = trip.maxKmh, max > 0 { row("Höchstgeschwindigkeit", "\(Int(max.rounded())) km/h") }
            }
            Section {
                if let gpxFile {
                    ShareLink(item: gpxFile) {
                        Label("Strecke als GPX teilen", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Text(trip.hasTrack == true ? "Strecke wird geladen …" : "Für diese Fahrt wurde keine Strecke aufgezeichnet.")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                if gpxFile != nil {
                    Text("GPX lässt sich in Komoot, Strava, Google Earth & Co. öffnen.")
                }
            }
        }
        .navigationTitle("Fahrt")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard trip.hasTrack == true else { return }
            let loaded = TripTrackStore.load(tripId: trip.id)
            points = loaded
            if loaded.count >= 2 { gpxFile = try? GPX.writeTemporaryFile(trip: trip, points: loaded) }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/** Kleine, nicht drehbare Karte mit der gefahrenen Strecke (Start grün, Ziel rot). */
private struct TripMapView: UIViewRepresentable {
    let points: [TrackPoint]
    let dark: Bool
    let lineHex: UInt32

    func makeCoordinator() -> Coordinator { Coordinator(points: points, lineHex: lineHex) }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: MapController.styleURL(engine: .vector, dark: dark))
        mapView.delegate = context.coordinator
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.compassView.compassVisibility = .hidden
        mapView.logoView.isHidden = true
        return mapView
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {}

    final class Coordinator: NSObject, MLNMapViewDelegate {
        let points: [TrackPoint]
        let lineHex: UInt32

        init(points: [TrackPoint], lineHex: UInt32) {
            self.points = points
            self.lineHex = lineHex
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            var coords = points.map(\.point.coordinate)
            let line = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
            let source = MLNShapeSource(identifier: "trip-track", shape: line, options: nil)
            style.addSource(source)
            let layer = MLNLineStyleLayer(identifier: "trip-track-line", source: source)
            layer.lineColor = NSExpression(forConstantValue: UIColor(hex: lineHex))
            layer.lineWidth = NSExpression(forConstantValue: 5)
            layer.lineCap = NSExpression(forConstantValue: "round")
            layer.lineJoin = NSExpression(forConstantValue: "round")
            style.addLayer(layer)

            let ends = [(coords.first!, UIColor.systemGreen), (coords.last!, UIColor.systemRed)].map { coordinate, color -> MLNPointFeature in
                let feature = MLNPointFeature()
                feature.coordinate = coordinate
                feature.attributes = ["color": color]
                return feature
            }
            let endSource = MLNShapeSource(identifier: "trip-ends", shape: MLNShapeCollectionFeature(shapes: ends), options: nil)
            style.addSource(endSource)
            let endLayer = MLNCircleStyleLayer(identifier: "trip-ends-layer", source: endSource)
            endLayer.circleRadius = NSExpression(forConstantValue: 6)
            endLayer.circleColor = NSExpression(forKeyPath: "color")
            endLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor.white)
            endLayer.circleStrokeWidth = NSExpression(forConstantValue: 2)
            style.addLayer(endLayer)

            let camera = mapView.cameraThatFitsShape(line, direction: 0,
                                                     edgePadding: UIEdgeInsets(top: 30, left: 30, bottom: 30, right: 30))
            mapView.setCamera(camera, animated: false)
        }
    }
}
