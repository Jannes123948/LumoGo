import CoreLocation
import UIKit

/**
 * Standort-Updates über CoreLocation (iOS fusioniert GPS/WLAN/Mobilfunk von sich aus — das
 * Pendant zu Androids FusedLocationProvider). Während der Navigation laufen die Updates auch im
 * Hintergrund weiter (`UIBackgroundModes: location`), damit Ansagen bei gesperrtem Display kommen.
 */
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    var onLocation: ((CLLocation) -> Void)?
    var onHeading: ((Double) -> Void)?
    /** Letzte verlässliche Kompassrichtung (Grad, geografisch Nord), nil = keine/zu ungenau. */
    private(set) var compassHeading: Double?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 3
        authorizationStatus = manager.authorizationStatus
        // Kompasswerte beziehen sich auf die Geräte-Oberkante — bei Querformat umrechnen lassen.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc private func orientationChanged() {
        switch UIDevice.current.orientation {
        case .portrait: manager.headingOrientation = .portrait
        case .portraitUpsideDown: manager.headingOrientation = .portraitUpsideDown
        case .landscapeLeft: manager.headingOrientation = .landscapeLeft
        case .landscapeRight: manager.headingOrientation = .landscapeRight
        default: break // flach liegend: letzte Ausrichtung behalten
        }
    }

    func start() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        // Sofort die letzte bekannte Position liefern, statt bis zum ersten frischen Fix zu warten.
        if let last = manager.location { onLocation?(last) }
        manager.startUpdatingLocation()
        startCompass()
    }

    private func startCompass() {
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    /** Hintergrund-Updates nur während aktiver Navigation (spart Akku, blauer Statusbalken). */
    func setNavigating(_ navigating: Bool) {
        manager.allowsBackgroundLocationUpdates = navigating
        manager.showsBackgroundLocationIndicator = navigating
        // Während der Navigation zählt nur die Fahrtrichtung, nie der Kompass (siehe CLAUDE.md).
        if navigating {
            manager.stopUpdatingHeading()
            compassHeading = nil
        } else {
            startCompass()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0, newHeading.headingAccuracy <= 40 else {
            compassHeading = nil
            return
        }
        let heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        compassHeading = heading
        onHeading?(heading)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        onLocation?(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Vorübergehende Fehler (kein Fix) einfach ignorieren — die Updates laufen weiter.
    }
}
