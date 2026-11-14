import Foundation

public enum Geo {
    public static func distance(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Double {
        let r = 6_371_008.8, rad = Double.pi / 180
        let dLat = (bLat - aLat) * rad, dLon = (bLon - aLon) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(aLat * rad) * cos(bLat * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }
    public static func offset(lat: Double, lon: Double, north: Double, east: Double) -> (lat: Double, lon: Double) {
        // Local flat-earth approximation; fine for the tens-of-km scales this app works at.
        let r = 6_371_008.8, rad = Double.pi / 180
        return (lat + north / r / rad, lon + east / (r * cos(lat * rad)) / rad)
    }
}
