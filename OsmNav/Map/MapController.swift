import UIKit
import MapLibre

/**
 * Kapselt die MapLibre-Karte (Pendant zu den Karten-Teilen von `MainActivity.kt`): Stil laden,
 * Quellen/Layer für Ziele, Routen und den eigenen Standort-Pfeil, Kamera-Steuerung, Long-Press.
 * Hält den zuletzt gezeichneten Zustand, damit er nach einem Stilwechsel (Hell/Dunkel) automatisch
 * neu aufgebaut werden kann — MapLibre verwirft beim Stilwechsel alle eigenen Quellen/Layer.
 */
/** Ein einfacher Tipp auf die Karte. [poiName]/[poiPoint] sind gesetzt, wenn ein POI-Symbol der
 *  Vektorkarte getroffen wurde; [hasPoiSymbols] = false bei Stilen ohne POI-Symbole (OSM-Raster,
 *  dunkler Stil) — dort sucht die App per Overpass den nächsten Ort im Umkreis [radiusMeters]. */
struct MapTap {
    let point: LatLon
    let poiName: String?
    let poiPoint: LatLon?
    let hasPoiSymbols: Bool
    let radiusMeters: Int
}

/** Alles an der Kartendarstellung, was in den Einstellungen wählbar ist. */
struct MapAppearance: Equatable {
    var emphasizeStreetNames = true
    var widerMotorways = true
    var buildings3D = true
    var routeColor: UInt32 = ColorKeys.defaultRoute
    var puckColor: UInt32 = ColorKeys.defaultPuck
    /** OSM-Rasterkarte drehbar (die Vektorkarte ist es immer). */
    var osmRotatable = true
}

final class MapController: NSObject, MLNMapViewDelegate, UIGestureRecognizerDelegate {

    static let lightStyleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    /** Angepasste Fassung von "dark-matter" für OpenFreeMap (siehe CLAUDE.md, Nachtmodus). */
    static let darkStyleURL = Bundle.main.url(forResource: "dark_style", withExtension: "json")!
    /** Klassische OSM-Rasterkacheln (tile.openstreetmap.org); dunkel = invertierte Farben wie der
     *  Farbfilter der osmdroid-Engine auf Android. Kein Massen-Download erlaubt (OSM-Richtlinie) —
     *  Offline-Pakete nutzen deshalb immer die Vektorkarte. */
    static let osmStyleURL = Bundle.main.url(forResource: "osm_raster_style", withExtension: "json")!
    static let osmDarkStyleURL = Bundle.main.url(forResource: "osm_raster_dark_style", withExtension: "json")!

    static func styleURL(engine: MapEngine, dark: Bool) -> URL {
        switch engine {
        case .vector: return dark ? darkStyleURL : lightStyleURL
        case .osm: return dark ? osmDarkStyleURL : osmStyleURL
        }
    }

    private static let destinationSourceId = "destinations"
    private static let destinationLayerId = "destinations-layer"
    private static let routeSourceId = "route"
    private static let routeLayerId = "route-layer"
    private static let routeCasingLayerId = "route-casing-layer"
    private static let routeAltSourceId = "route-alt"
    private static let routeAltLayerId = "route-alt-layer"
    private static let puckSourceId = "user-puck"
    private static let puckLayerId = "user-puck-layer"
    private static let destinationIcon = "destination-pin"
    private static let waypointIcon = "waypoint-dot"
    private static let puckIcon = "nav-arrow"
    private static let tourSourceId = "tour-track"
    private static let tourLayerId = "tour-track-layer"
    private static let selectedPoiSourceId = "selected-poi"
    private static let selectedPoiLayerId = "selected-poi-layer"
    /** Quell-Layer der OpenMapTiles-Kacheln, deren Symbole antippbar sind. */
    private static let tappableSourceLayers: Set<String> = ["poi", "aerodrome_label"]

    private(set) weak var mapView: MLNMapView?
    private var style: MLNStyle?
    private var currentStyleURL: URL?
    private(set) var engine: MapEngine = .vector

    private(set) var appearance = MapAppearance()
    var onLongPress: ((LatLon) -> Void)?
    var onTap: ((MapTap) -> Void)?
    /** Kartenrichtung (Grad, 0 = Norden oben) — für den eigenen Kompass-Knopf. */
    var onDirectionChange: ((Double) -> Void)?
    /** Wird gerufen, wenn der Nutzer die Karte per Geste bewegt (Follow-Modus aus). */
    var onUserGesture: (() -> Void)?

    // Zuletzt gezeichneter Zustand (für Neuaufbau nach Stilwechsel)
    private var destinations: [LatLon] = []
    private var routes: [[LatLon]] = []
    private var selectedRouteIndex = 0
    private var puck: (LatLon, Double)?

    // Flüssiger Pfeil (siehe updatePuck)
    var smoothPuck = true
    private struct CameraFollow {
        let fromZoom: Double, fromPitch: Double, fromHeading: Double
        let toZoom: Double?, toPitch: Double?, toHeading: Double?
    }
    private struct PuckAnimation {
        let from: LatLon, to: LatLon
        let fromHeading: Double, toHeading: Double
        let start: CFTimeInterval, duration: CFTimeInterval
        var camera: CameraFollow?
    }
    private var puckAnimation: PuckAnimation?
    private var displayLink: CADisplayLink?
    private var lastPuckFix: CFTimeInterval = 0
    /** Gerade gezeichnete (ggf. Zwischen-)Position des Pfeils. */
    private var drawnPuck: (LatLon, Double)?
    /** Weiter als das (GPS-Sprung, Neustart) springt der Pfeil direkt. */
    private static let maxGlideMeters = 150.0
    /** Anteil der Kartenhöhe, um den der Mittelpunkt in der Navigation nach unten rückt (Pfeil bei ≈ 70 %). */
    private static let puckLowInsetFraction = 0.4
    /** Wo der Pfeil dann auf dem Bildschirm steht (Mitte des eingerückten Bereichs) — für die
     *  Straßennamen-Leiste direkt darunter. */
    static let puckLowScreenFraction = puckLowInsetFraction + (1 - puckLowInsetFraction) / 2
    /** Halbe Pfeilgröße + Abstand: so weit unter der Pfeilmitte beginnt die Namensleiste. */
    static let puckLabelOffset: CGFloat = 23 + 8
    private var selectedPoi: LatLon?
    private var tourTrack: [LatLon] = []

    func makeMapView(engine: MapEngine, dark: Bool) -> MLNMapView {
        Self.configureNetwork()
        let styleURL = Self.styleURL(engine: engine, dark: dark)
        let mapView = MLNMapView(frame: UIScreen.main.bounds, styleURL: styleURL)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.showsUserLocation = false // eigener Pfeil (gesnappte Position), siehe updatePuck
        mapView.setCenter(CLLocationCoordinate2D(latitude: 51.1657, longitude: 10.4515), zoomLevel: 5, animated: false)
        mapView.maximumZoomLevel = 20
        // Eigener Kompass-Knopf in der Knopfspalte statt MapLibres Kompass oben rechts — der lag
        // während der Navigation unter der Navi-Anzeige.
        mapView.compassView.compassVisibility = .hidden

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.delegate = self
        mapView.addGestureRecognizer(longPress)

        // Einfacher Tipp = Ort-Infos; muss auf MapLibres Doppeltipp-Zoom warten.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        for recognizer in mapView.gestureRecognizers ?? [] {
            if let doubleTap = recognizer as? UITapGestureRecognizer, doubleTap.numberOfTapsRequired == 2 {
                tap.require(toFail: doubleTap)
            }
        }
        mapView.addGestureRecognizer(tap)

        self.mapView = mapView
        currentStyleURL = styleURL
        applyEngine(engine)
        return mapView
    }

    func setStyle(engine: MapEngine, dark: Bool) {
        guard let mapView else { return }
        if engine != self.engine { applyEngine(engine) }
        let url = Self.styleURL(engine: engine, dark: dark)
        guard url != currentStyleURL else { return }
        currentStyleURL = url
        style = nil
        mapView.styleURL = url
    }

    /** Karte darf gedreht werden: Vektorkarte immer, OSM-Karte je nach Einstellung. */
    private var rotationAllowed: Bool { engine.supports3D || appearance.osmRotatable }

    /** OSM-Karte: nie geneigt (gekippte Rasterkacheln werden unscharf), drehbar nur per Einstellung. */
    private func applyEngine(_ engine: MapEngine) {
        self.engine = engine
        guard let mapView else { return }
        mapView.isRotateEnabled = rotationAllowed
        mapView.isPitchEnabled = engine.supports3D
        let resetHeading = !rotationAllowed && mapView.direction != 0
        if (!engine.supports3D && mapView.camera.pitch != 0) || resetHeading {
            ease(pitch: 0, heading: resetHeading ? 0 : nil, duration: 0.3)
        }
    }

    /** Die OSM-Kachelserver verlangen einen eindeutigen User-Agent (wie osmdroids
     *  `userAgentValue` auf Android), sonst drohen gesperrte Kachel-Downloads. */
    private static var networkConfigured = false
    /** Muss vor JEDER MapLibre-Nutzung laufen (Karte UND Offline-Speicher) — MapLibre kopiert die
     *  Session-Konfiguration beim ersten Gebrauch; deshalb schon im App-Start aufgerufen. */
    static func configureNetwork() {
        guard !networkConfigured else { return }
        networkConfigured = true
        let config = MLNNetworkConfiguration.sharedManager.sessionConfiguration ?? URLSessionConfiguration.default
        var headers = config.httpAdditionalHeaders ?? [:]
        headers["User-Agent"] = HTTP.userAgent
        config.httpAdditionalHeaders = headers
        // Offline-Modus: eigenes Protokoll vor allen anderen — prüft jede Anfrage einzeln.
        config.protocolClasses = [OfflineBlockingURLProtocol.self] + (config.protocolClasses ?? [])
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = config
        // Offline-Modus: Kartenanfragen abfangen (siehe NetworkPolicy).
        MLNNetworkConfiguration.sharedManager.delegate = MapNetworkGate.shared
    }

    // MARK: - Delegate

    func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        self.style = style
        setupSources(style)
        if appearance.widerMotorways { emphasizeMotorwayWidth(style) }
        if appearance.emphasizeStreetNames { emphasizeStreetNameLabels(style) }
        applyBuildings(style)
        redrawAll()
    }

    func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
        let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]
        if !reason.intersection(gestures).isEmpty {
            puckAnimation?.camera = nil
            onUserGesture?()
        }
    }

    func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        onDirectionChange?(mapView.direction)
    }

    func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        onDirectionChange?(mapView.direction)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let mapView else { return }
        let coordinate = mapView.convert(gesture.location(in: mapView), toCoordinateFrom: mapView)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onLongPress?(LatLon(coordinate))
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let mapView else { return }
        let location = gesture.location(in: mapView)
        let coordinate = mapView.convert(location, toCoordinateFrom: mapView)

        let poiLayers = Set((style?.layers ?? []).compactMap { layer -> String? in
            guard let vector = layer as? MLNVectorStyleLayer,
                  let sourceLayer = vector.sourceLayerIdentifier,
                  Self.tappableSourceLayers.contains(sourceLayer) else { return nil }
            return layer.identifier
        })
        var hit: (name: String, point: LatLon)?
        if !poiLayers.isEmpty {
            let rect = CGRect(x: location.x - 22, y: location.y - 22, width: 44, height: 44)
            let features = mapView.visibleFeatures(in: rect, styleLayerIdentifiers: poiLayers)
            let nearest = features
                .compactMap { feature -> (String, CLLocationCoordinate2D, CGFloat)? in
                    guard let name = feature.attribute(forKey: "name") as? String, !name.isEmpty else { return nil }
                    let screen = mapView.convert(feature.coordinate, toPointTo: mapView)
                    return (name, feature.coordinate, hypot(screen.x - location.x, screen.y - location.y))
                }
                .min { $0.2 < $1.2 }
            if let nearest { hit = (nearest.0, LatLon(nearest.1)) }
        }
        // Suchradius ≈ 30 pt auf dem Bildschirm, damit ein Tipp "auf" ein Gebäude/Symbol trifft.
        let meters = mapView.metersPerPoint(atLatitude: coordinate.latitude) * 30
        onTap?(MapTap(
            point: LatLon(coordinate),
            poiName: hit?.name,
            poiPoint: hit?.point,
            hasPoiSymbols: !poiLayers.isEmpty,
            radiusMeters: Int(min(max(meters, 20), 120))
        ))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Quellen & Layer

    /**
     * Übernimmt geänderte Darstellungs-Einstellungen. Farben und 3D-Gebäude gehen sofort;
     * Straßennamen/Autobahnbreite ändern Layer des Kartenstils → Stil neu laden (die eigenen
     * Quellen/Layer baut didFinishLoading ohnehin wieder auf).
     */
    func apply(_ new: MapAppearance) {
        let old = appearance
        guard new != old else { return }
        appearance = new
        if new.osmRotatable != old.osmRotatable { applyEngine(engine) }
        guard let style, let mapView else { return }
        if new.emphasizeStreetNames != old.emphasizeStreetNames || new.widerMotorways != old.widerMotorways {
            self.style = nil
            mapView.reloadStyle(nil)
            return
        }
        if new.buildings3D != old.buildings3D { applyBuildings(style) }
        if new.routeColor != old.routeColor { applyRouteColor(style) }
        if new.puckColor != old.puckColor { style.setImage(Self.renderPuck(new.puckColor), forName: Self.puckIcon) }
    }

    private func applyBuildings(_ style: MLNStyle) {
        for layer in style.layers where layer is MLNFillExtrusionStyleLayer {
            layer.isVisible = appearance.buildings3D
        }
    }

    private func applyRouteColor(_ style: MLNStyle) {
        let color = UIColor(hex: appearance.routeColor)
        (style.layer(withIdentifier: Self.routeLayerId) as? MLNLineStyleLayer)?.lineColor = NSExpression(forConstantValue: color)
        (style.layer(withIdentifier: Self.routeCasingLayerId) as? MLNLineStyleLayer)?.lineColor = NSExpression(forConstantValue: color.darker())
    }

    private func setupSources(_ style: MLNStyle) {
        style.setImage(Self.renderPin(), forName: Self.destinationIcon)
        style.setImage(Self.renderDot(), forName: Self.waypointIcon)
        style.setImage(Self.renderPuck(appearance.puckColor), forName: Self.puckIcon)

        // GPX-Tour: Originalspur gestrichelt UNTER den Routen (die berechnete Route bleibt sichtbar).
        let tourSource = MLNShapeSource(identifier: Self.tourSourceId, shape: nil, options: nil)
        style.addSource(tourSource)
        let tourLayer = MLNLineStyleLayer(identifier: Self.tourLayerId, source: tourSource)
        tourLayer.lineColor = NSExpression(forConstantValue: UIColor(red: 0.95, green: 0.45, blue: 0.1, alpha: 0.9))
        tourLayer.lineWidth = NSExpression(forConstantValue: 4)
        tourLayer.lineDashPattern = NSExpression(forConstantValue: [2, 1.5])
        tourLayer.lineCap = NSExpression(forConstantValue: "round")
        style.addLayer(tourLayer)

        let altSource = MLNShapeSource(identifier: Self.routeAltSourceId, shape: nil, options: nil)
        style.addSource(altSource)
        let altLayer = MLNLineStyleLayer(identifier: Self.routeAltLayerId, source: altSource)
        altLayer.lineColor = NSExpression(forConstantValue: UIColor(white: 0.62, alpha: 1))
        altLayer.lineWidth = NSExpression(forConstantValue: 5)
        altLayer.lineCap = NSExpression(forConstantValue: "round")
        altLayer.lineJoin = NSExpression(forConstantValue: "round")
        style.addLayer(altLayer)

        let routeSource = MLNShapeSource(identifier: Self.routeSourceId, shape: nil, options: nil)
        style.addSource(routeSource)
        let casing = MLNLineStyleLayer(identifier: Self.routeCasingLayerId, source: routeSource)
        casing.lineColor = NSExpression(forConstantValue: UIColor(hex: appearance.routeColor).darker())
        casing.lineWidth = NSExpression(forConstantValue: 9)
        casing.lineCap = NSExpression(forConstantValue: "round")
        casing.lineJoin = NSExpression(forConstantValue: "round")
        style.addLayer(casing)
        let routeLayer = MLNLineStyleLayer(identifier: Self.routeLayerId, source: routeSource)
        routeLayer.lineColor = NSExpression(forConstantValue: UIColor(hex: appearance.routeColor))
        routeLayer.lineWidth = NSExpression(forConstantValue: 6)
        routeLayer.lineCap = NSExpression(forConstantValue: "round")
        routeLayer.lineJoin = NSExpression(forConstantValue: "round")
        style.addLayer(routeLayer)

        let destSource = MLNShapeSource(identifier: Self.destinationSourceId, shape: nil, options: nil)
        style.addSource(destSource)
        let destLayer = MLNSymbolStyleLayer(identifier: Self.destinationLayerId, source: destSource)
        // Datengetriebenes Icon: Endziel = Pin, Zwischenziele = kleiner Punkt.
        destLayer.iconImageName = NSExpression(forKeyPath: "icon")
        destLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
        destLayer.iconAnchor = NSExpression(forKeyPath: "anchor")
        style.addLayer(destLayer)

        // Markierung des angetippten Orts (Ring), unter dem Standort-Pfeil.
        let selectedSource = MLNShapeSource(identifier: Self.selectedPoiSourceId, shape: nil, options: nil)
        style.addSource(selectedSource)
        let selectedLayer = MLNCircleStyleLayer(identifier: Self.selectedPoiLayerId, source: selectedSource)
        selectedLayer.circleRadius = NSExpression(forConstantValue: 14)
        selectedLayer.circleColor = NSExpression(forConstantValue: UIColor(red: 0x29 / 255, green: 0x62 / 255, blue: 1, alpha: 0.18))
        selectedLayer.circleStrokeColor = NSExpression(forConstantValue: UIColor(red: 0x29 / 255, green: 0x62 / 255, blue: 1, alpha: 1))
        selectedLayer.circleStrokeWidth = NSExpression(forConstantValue: 3)
        style.addLayer(selectedLayer)

        // Standort-Pfeil zuoberst, flach auf der Karte und mit der Fahrtrichtung gedreht.
        let puckSource = MLNShapeSource(identifier: Self.puckSourceId, shape: nil, options: nil)
        style.addSource(puckSource)
        let puckLayer = MLNSymbolStyleLayer(identifier: Self.puckLayerId, source: puckSource)
        puckLayer.iconImageName = NSExpression(forConstantValue: Self.puckIcon)
        puckLayer.iconAllowsOverlap = NSExpression(forConstantValue: true)
        puckLayer.iconIgnoresPlacement = NSExpression(forConstantValue: true)
        puckLayer.iconRotation = NSExpression(forKeyPath: "heading")
        puckLayer.iconRotationAlignment = NSExpression(forConstantValue: "map")
        puckLayer.iconPitchAlignment = NSExpression(forConstantValue: "map")
        style.addLayer(puckLayer)
    }

    /** Autobahnen/Schnellstraßen optisch breiter (rein optisch — die Kacheln enthalten keine
     *  Fahrstreifenzahl). Nicht existierende Layer-IDs (anderer Stil) werden übersprungen. */
    private func emphasizeMotorwayWidth(_ style: MLNStyle) {
        let width = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.2, %@)",
                                 [5: 0, 12: 4, 16: 14, 20: 30])
        let casingWidth = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'exponential', 1.2, %@)",
                                       [5: 0.4, 12: 5, 16: 17, 20: 36])
        for id in ["road_motorway", "road_trunk_primary", "bridge_motorway", "bridge_trunk_primary", "tunnel_motorway", "tunnel_trunk_primary", "highway_motorway_inner"] {
            (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineWidth = width
        }
        for id in ["road_motorway_casing", "road_trunk_primary_casing", "bridge_motorway_casing", "bridge_trunk_primary_casing", "tunnel_motorway_casing", "tunnel_trunk_primary_casing", "highway_motorway_casing"] {
            (style.layer(withIdentifier: id) as? MLNLineStyleLayer)?.lineWidth = casingWidth
        }
    }

    /** Straßennamen größer + breiterer Halo; Schild-/Nummern-Layer (mit `icon-image`) ausgenommen. */
    private func emphasizeStreetNameLabels(_ style: MLNStyle) {
        let size = NSExpression(format: "mgl_interpolate:withCurveType:parameters:stops:($zoomLevel, 'linear', nil, %@)",
                                [11: 12, 14: 15, 18: 19])
        for layer in style.layers {
            guard let symbol = layer as? MLNSymbolStyleLayer,
                  symbol.sourceLayerIdentifier == "transportation_name",
                  symbol.iconImageName == nil else { continue }
            symbol.textFontSize = size
            symbol.textHaloWidth = NSExpression(forConstantValue: 1.8)
        }
    }

    // MARK: - Zeichnen

    func setDestinations(_ points: [LatLon]) {
        destinations = points
        guard let source = style?.source(withIdentifier: Self.destinationSourceId) as? MLNShapeSource else { return }
        let features: [MLNPointFeature] = points.enumerated().map { index, point in
            let feature = MLNPointFeature()
            feature.coordinate = point.coordinate
            let isFinal = index == points.count - 1
            feature.attributes = [
                "icon": isFinal ? Self.destinationIcon : Self.waypointIcon,
                "anchor": isFinal ? "bottom" : "center"
            ]
            return feature
        }
        source.shape = MLNShapeCollectionFeature(shapes: features)
    }

    func setRoutes(_ routes: [[LatLon]], selected: Int) {
        self.routes = routes
        selectedRouteIndex = selected
        guard let style,
              let routeSource = style.source(withIdentifier: Self.routeSourceId) as? MLNShapeSource,
              let altSource = style.source(withIdentifier: Self.routeAltSourceId) as? MLNShapeSource else { return }
        func line(_ points: [LatLon]) -> MLNPolylineFeature {
            var coords = points.map(\.coordinate)
            return MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
        }
        routeSource.shape = routes.indices.contains(selected) ? line(routes[selected]) : nil
        let alternatives = routes.enumerated().filter { $0.offset != selected }.map { line($0.element) }
        altSource.shape = MLNShapeCollectionFeature(shapes: alternatives)
    }

    /** Originalspur einer GPX-Tour; leer = ausblenden. */
    func setTourTrack(_ points: [LatLon]) {
        tourTrack = points
        guard let source = style?.source(withIdentifier: Self.tourSourceId) as? MLNShapeSource else { return }
        guard points.count >= 2 else {
            source.shape = nil
            return
        }
        var coords = points.map(\.coordinate)
        source.shape = MLNPolylineFeature(coordinates: &coords, count: UInt(coords.count))
    }

    /**
     * Neue Pfeil-Position. Mit [smoothPuck] gleitet der Pfeil Bild für Bild dorthin, und zwar so lange,
     * wie der letzte GPS-Fix her ist — beim nächsten Fix ist er gerade angekommen, er bleibt also nie
     * stehen und springt nie (vorher: Sprung je Fix + 1-s-Kamerafahrt hinterher = Ruckeln).
     */
    func updatePuck(_ position: LatLon, heading: Double) {
        puck = (position, heading)
        let now = CACurrentMediaTime()
        let interval = now - lastPuckFix
        lastPuckFix = now
        guard smoothPuck, mapView != nil, let (from, fromHeading) = drawnPuck,
              GeoUtils.distanceMeters(from, position) < Self.maxGlideMeters else {
            stopPuckAnimation()
            drawPuck(position, heading: heading)
            return
        }
        puckAnimation = PuckAnimation(
            from: from, to: position, fromHeading: fromHeading, toHeading: heading,
            start: now, duration: min(max(interval, 0.2), 1.2), camera: nil
        )
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(stepPuckAnimation(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    /**
     * Kamera folgt dem Pfeil. Gleitet er gerade, fährt die Kamera Bild für Bild mit (Pfeil bleibt an
     * seiner Bildschirmstelle), sonst wie bisher per [ease].
     */
    func followPuck(zoom: Double? = nil, pitch: Double? = nil, heading: Double? = nil) {
        guard let mapView else { return }
        if var animation = puckAnimation {
            animation.camera = CameraFollow(
                fromZoom: mapView.zoomLevel, fromPitch: Double(mapView.camera.pitch), fromHeading: mapView.direction,
                toZoom: zoom, toPitch: pitch, toHeading: heading
            )
            puckAnimation = animation
        } else if let (position, _) = puck {
            ease(center: position, zoom: zoom, pitch: pitch, heading: heading)
        }
    }

    /** Pfeil in der Navigation weiter unten im Bild (wie Google Maps) — mehr Strecke voraus sichtbar. */
    func setPuckLow(_ low: Bool) {
        guard let mapView else { return }
        if low {
            mapView.automaticallyAdjustsContentInset = false
            let top = mapView.bounds.height * Self.puckLowInsetFraction
            mapView.setContentInset(UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0), animated: true, completionHandler: nil)
        } else if !mapView.automaticallyAdjustsContentInset {
            mapView.setContentInset(.zero, animated: true, completionHandler: nil)
            mapView.automaticallyAdjustsContentInset = true
        }
    }

    private func drawPuck(_ position: LatLon, heading: Double) {
        drawnPuck = (position, heading)
        guard let source = style?.source(withIdentifier: Self.puckSourceId) as? MLNShapeSource else { return }
        let feature = MLNPointFeature()
        feature.coordinate = position.coordinate
        feature.attributes = ["heading": heading]
        source.shape = feature
    }

    @objc private func stepPuckAnimation(_ link: CADisplayLink) {
        guard let animation = puckAnimation else {
            stopPuckAnimation()
            return
        }
        // Linear: der Pfeil fährt mit gleichmäßigem Tempo von Fix zu Fix (kein Abbremsen je Fix).
        let t = min(1, (CACurrentMediaTime() - animation.start) / animation.duration)
        let position = LatLon(
            animation.from.latitude + (animation.to.latitude - animation.from.latitude) * t,
            animation.from.longitude + (animation.to.longitude - animation.from.longitude) * t
        )
        drawPuck(position, heading: Self.interpolateAngle(animation.fromHeading, animation.toHeading, t))
        if let camera = animation.camera, let mapView, mapView.bounds.height > 0 {
            let zoom = camera.fromZoom + ((camera.toZoom ?? camera.fromZoom) - camera.fromZoom) * t
            let pitch = camera.fromPitch + ((camera.toPitch ?? camera.fromPitch) - camera.fromPitch) * t
            let heading = Self.interpolateAngle(camera.fromHeading, camera.toHeading ?? camera.fromHeading, t)
            mapView.setCamera(MLNMapCamera(
                lookingAtCenter: position.coordinate,
                altitude: Self.altitude(forZoom: zoom, pitch: pitch, latitude: position.latitude, viewHeight: Double(mapView.bounds.height)),
                pitch: CGFloat(pitch),
                heading: heading
            ), animated: false)
        }
        if t >= 1 { stopPuckAnimation() }
    }

    private func stopPuckAnimation() {
        puckAnimation = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    /** Kürzester Weg zwischen zwei Richtungen (350° → 10° dreht über Norden, nicht zurück). */
    private static func interpolateAngle(_ from: Double, _ to: Double, _ t: Double) -> Double {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        let result = (from + delta * t).truncatingRemainder(dividingBy: 360)
        return result < 0 ? result + 360 : result
    }

    func setSelectedPoi(_ point: LatLon?) {
        selectedPoi = point
        guard let source = style?.source(withIdentifier: Self.selectedPoiSourceId) as? MLNShapeSource else { return }
        if let point {
            let feature = MLNPointFeature()
            feature.coordinate = point.coordinate
            source.shape = feature
        } else {
            source.shape = nil
        }
    }

    private func redrawAll() {
        setDestinations(destinations)
        setSelectedPoi(selectedPoi)
        setTourTrack(tourTrack)
        setRoutes(routes, selected: selectedRouteIndex)
        if let (position, heading) = drawnPuck ?? puck { drawPuck(position, heading: heading) }
    }

    // MARK: - Kamera

    var zoomLevel: Double { mapView?.zoomLevel ?? 15 }

    var visibleBounds: BoundingBox? {
        guard let bounds = mapView?.visibleCoordinateBounds else { return nil }
        return BoundingBox(south: bounds.sw.latitude, north: bounds.ne.latitude, west: bounds.sw.longitude, east: bounds.ne.longitude)
    }

    /** Animierte Kamerafahrt; nicht gesetzte Werte bleiben wie aktuell. */
    func ease(center: LatLon? = nil, zoom: Double? = nil, pitch: Double? = nil, heading: Double? = nil, duration: TimeInterval = 1) {
        guard let mapView, mapView.bounds.height > 0 else { return }
        puckAnimation?.camera = nil // sonst überschreibt das nächste Bild die Kamerafahrt
        let target = center?.coordinate ?? mapView.centerCoordinate
        let p = pitch ?? Double(mapView.camera.pitch)
        let z = zoom ?? mapView.zoomLevel
        let camera = MLNMapCamera(
            lookingAtCenter: target,
            altitude: Self.altitude(forZoom: z, pitch: p, latitude: target.latitude, viewHeight: Double(mapView.bounds.height)),
            pitch: CGFloat(p),
            heading: heading ?? mapView.direction
        )
        mapView.setCamera(camera, withDuration: duration, animationTimingFunction: CAMediaTimingFunction(name: .easeInEaseOut))
    }

    /** Nachbau von MapLibres (privatem) `MLNAltitudeForZoomLevel` — `MLNMapCamera` arbeitet mit
     *  Kamerahöhe statt Zoomstufe. */
    private static func altitude(forZoom zoom: Double, pitch: Double, latitude: Double, viewHeight: Double) -> Double {
        let metersPerPixel = cos(latitude * .pi / 180) * 2 * .pi * 6_378_137 / (512 * pow(2, zoom))
        let metersTall = metersPerPixel * viewHeight
        let fieldOfView = 30.0 * .pi / 180
        let altitude = metersTall / 2 / tan(fieldOfView / 2)
        return altitude * sin(.pi / 2 - pitch * .pi / 180) / sin(.pi / 2)
    }

    // MARK: - Icons

    private static func renderPin() -> UIImage {
        let config = UIImage.SymbolConfiguration(pointSize: 40, weight: .bold)
        let symbol = UIImage(systemName: "mappin.circle.fill", withConfiguration: config)!
            .withTintColor(UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1), renderingMode: .alwaysOriginal)
        let size = CGSize(width: 44, height: 56)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let stem = UIBezierPath()
            stem.move(to: CGPoint(x: 18, y: 38))
            stem.addLine(to: CGPoint(x: 22, y: 56))
            stem.addLine(to: CGPoint(x: 26, y: 38))
            stem.close()
            UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill()
            stem.fill()
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 4, y: 2, width: 36, height: 36))
            symbol.draw(in: CGRect(x: 2, y: 0, width: 40, height: 40))
        }
    }

    private static func renderDot() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 22, height: 22))
            UIColor(red: 1, green: 0.6, blue: 0, alpha: 1).setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 4, y: 4, width: 14, height: 14))
        }
    }

    private static func renderPuck(_ hex: UInt32) -> UIImage {
        let color = UIColor(hex: hex)
        // Heller Pfeil (z.B. Weiß): dunkler Rand + dunkle Pfeilspitze, sonst wäre er unsichtbar.
        let light = HexColor.isLight(hex)
        let size: CGFloat = 46
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { ctx in
            let cg = ctx.cgContext
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            (light ? UIColor(white: 0.2, alpha: 1) : UIColor.white).setFill()
            cg.fillEllipse(in: CGRect(x: 3, y: 3, width: size - 6, height: size - 6))
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            color.setFill()
            cg.fillEllipse(in: CGRect(x: 6, y: 6, width: size - 12, height: size - 12))
            // Pfeil zeigt bei heading 0 nach Norden (oben).
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: size / 2, y: 11))
            arrow.addLine(to: CGPoint(x: size - 14, y: size - 13))
            arrow.addLine(to: CGPoint(x: size / 2, y: size - 18))
            arrow.addLine(to: CGPoint(x: 14, y: size - 13))
            arrow.close()
            UIColor(hex: HexColor.contrastText(on: hex)).setFill()
            arrow.fill()
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /** Dunklere Variante (Routen-Umrandung). */
    func darker(by factor: CGFloat = 0.6) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * factor, green: g * factor, blue: b * factor, alpha: a)
    }
}
