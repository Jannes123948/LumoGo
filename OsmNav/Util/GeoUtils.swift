import Foundation

enum GeoUtils {

    static let earthRadiusMeters = 6_371_000.0

    /** Haversine-Distanz in Metern zwischen zwei Punkten (Luftlinie). */
    static func distanceMeters(_ a: LatLon, _ b: LatLon) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLat = (b.latitude - a.latitude) * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180

        let h = sin(deltaLat / 2) * sin(deltaLat / 2) +
            cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        let c = 2 * atan2(sqrt(h), sqrt(1 - h))
        return earthRadiusMeters * c
    }

    /**
     * Nächster Punkt auf der Strecke [a]-[b] zu [p] ("Snap to road"). Rechnet in einer lokalen,
     * flachen Meter-Projektion um [a] — für die kurzen Segmente einer Routengeometrie ist der
     * Fehler gegenüber einer echten Großkreis-Projektion vernachlässigbar.
     */
    static func closestPointOnSegment(_ p: LatLon, _ a: LatLon, _ b: LatLon) -> LatLon {
        let metersPerDegLat = earthRadiusMeters * .pi / 180
        let metersPerDegLon = metersPerDegLat * cos(a.latitude * .pi / 180)

        let bx = (b.longitude - a.longitude) * metersPerDegLon
        let by = (b.latitude - a.latitude) * metersPerDegLat
        let px = (p.longitude - a.longitude) * metersPerDegLon
        let py = (p.latitude - a.latitude) * metersPerDegLat

        let lengthSquared = bx * bx + by * by
        let t = lengthSquared == 0 ? 0 : min(max((px * bx + py * by) / lengthSquared, 0), 1)

        return LatLon(a.latitude + t * by / metersPerDegLat, a.longitude + t * bx / metersPerDegLon)
    }

    /** Kompassrichtung von [a] nach [b] in Grad (0 = Norden, im Uhrzeigersinn). */
    static func bearing(_ a: LatLon, _ b: LatLon) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    static func bboxAround(_ center: LatLon, radiusMeters: Double) -> BoundingBox {
        let latDelta = radiusMeters / 111_320.0
        let lonDelta = radiusMeters / (111_320.0 * cos(center.latitude * .pi / 180))
        return BoundingBox(
            south: center.latitude - latDelta,
            north: center.latitude + latDelta,
            west: center.longitude - lonDelta,
            east: center.longitude + lonDelta
        )
    }
}
