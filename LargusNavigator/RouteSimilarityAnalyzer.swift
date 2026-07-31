import Foundation
import CoreLocation

enum RouteSimilarityAnalyzer {
    static func differingShare(
        route: [CLLocationCoordinate2D],
        reference: [CLLocationCoordinate2D],
        thresholdMeters: Double = 5_000
    ) -> Double {
        guard !route.isEmpty, !reference.isEmpty else { return 1 }
        let step = max(1, reference.count / 700)
        let refs = stride(from: 0, to: reference.count, by: step).map { reference[$0] }
        let routeStep = max(1, route.count / 900)
        var checked = 0
        var differing = 0

        for index in stride(from: 0, to: route.count, by: routeStep) {
            checked += 1
            let point = CLLocation(latitude: route[index].latitude, longitude: route[index].longitude)
            let nearReference = refs.contains {
                point.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= thresholdMeters
            }
            if !nearReference { differing += 1 }
        }
        return checked > 0 ? Double(differing) / Double(checked) : 1
    }

    static func differingSegments(
        route: [CLLocationCoordinate2D],
        reference: [CLLocationCoordinate2D],
        thresholdMeters: Double = 5_000
    ) -> [[CLLocationCoordinate2D]] {
        guard route.count >= 2, !reference.isEmpty else { return [route] }
        let step = max(1, reference.count / 800)
        let refs = stride(from: 0, to: reference.count, by: step).map { reference[$0] }
        var segments: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []

        for coordinate in route {
            let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let differs = !refs.contains {
                point.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) <= thresholdMeters
            }
            if differs {
                current.append(coordinate)
            } else if current.count >= 2 {
                segments.append(current)
                current = []
            } else {
                current = []
            }
        }
        if current.count >= 2 { segments.append(current) }
        return segments
    }
}
