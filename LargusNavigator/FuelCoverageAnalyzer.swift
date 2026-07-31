import Foundation
import CoreLocation

struct FuelCoverageGap: Identifiable, Equatable, Sendable {
    let id: String
    let startKM: Double
    let endKM: Double
    let coordinates: [CLLocationCoordinate2D]

    static func == (lhs: FuelCoverageGap, rhs: FuelCoverageGap) -> Bool {
        lhs.id == rhs.id
    }
}

enum FuelCoverageAnalyzer {
    static func gaps(
        stations: [RoutePOI],
        route: [CLLocationCoordinate2D],
        thresholdKM: Double = 80
    ) -> [FuelCoverageGap] {
        guard route.count >= 2 else { return [] }
        let cumulative = cumulativeDistances(route)
        guard let length = cumulative.last, length > 0 else { return [] }
        let positions = stations.compactMap(\.routeProgressKM).sorted()
        let boundaries = [0.0] + positions + [length]
        var result: [FuelCoverageGap] = []

        for index in 1..<boundaries.count {
            let start = boundaries[index - 1]
            let end = boundaries[index]
            guard end - start > thresholdKM else { continue }
            let coords = zip(route, cumulative)
                .filter { $0.1 >= start && $0.1 <= end }
                .map(\.0)
            guard coords.count >= 2 else { continue }
            result.append(FuelCoverageGap(
                id: String(format: "%.1f-%.1f", start, end),
                startKM: start,
                endKM: end,
                coordinates: coords
            ))
        }
        return result
    }

    private static func cumulativeDistances(_ route: [CLLocationCoordinate2D]) -> [Double] {
        var values = [0.0]
        var total = 0.0
        for index in 1..<route.count {
            total += CLLocation(latitude: route[index - 1].latitude, longitude: route[index - 1].longitude)
                .distance(from: CLLocation(latitude: route[index].latitude, longitude: route[index].longitude)) / 1000
            values.append(total)
        }
        return values
    }
}
