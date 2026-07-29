import Foundation
import MapKit
import CoreLocation

@MainActor
final class ApplePOIService {
    static let shared = ApplePOIService()

    private init() {}

    func points(
        for category: RoutePOICategory,
        coordinates: [OSMCoordinate]
    ) async -> [RoutePOI] {
        switch category {
        case .fuel:
            let osm = await OSMFuelService.shared.majorFuelStations(along: coordinates)
            if !osm.isEmpty { return osm }

            let fallback = await nativeFuelStations(along: coordinates)
            return merge(osm, fallback)

        case .hotel:
            return await localSearch(
                query: "отель",
                category: .hotel,
                coordinates: coordinates,
                spacingMeters: 110_000,
                maxSamples: 12,
                searchRadiusMeters: 55_000,
                maxDistanceFromRoute: 10_000
            )

        case .food:
            return await localSearch(
                query: "кафе ресторан",
                category: .food,
                coordinates: coordinates,
                spacingMeters: 90_000,
                maxSamples: 14,
                searchRadiusMeters: 45_000,
                maxDistanceFromRoute: 5_000
            )

        case .grocery:
            return await localSearch(
                query: "супермаркет продукты",
                category: .grocery,
                coordinates: coordinates,
                spacingMeters: 100_000,
                maxSamples: 12,
                searchRadiusMeters: 45_000,
                maxDistanceFromRoute: 5_000
            )
        }
    }

    private func nativeFuelStations(
        along coordinates: [OSMCoordinate]
    ) async -> [RoutePOI] {
        let samples = sampleByDistance(
            coordinates,
            spacingMeters: 80_000,
            maxCount: 18
        )
        var result: [RoutePOI] = []
        var seen = Set<String>()

        for point in samples {
            let center = CLLocationCoordinate2D(
                latitude: point.latitude,
                longitude: point.longitude
            )
            let request = MKLocalPointsOfInterestRequest(
                center: center,
                radius: 50_000
            )
            request.pointOfInterestFilter = MKPointOfInterestFilter(
                including: [.gasStation]
            )

            do {
                let response = try await MKLocalSearch(request: request).start()
                for item in response.mapItems.prefix(15) {
                    let rawName = item.name ?? ""
                    guard let brand = recognisedFuelBrand(in: rawName) else { continue }
                    guard !looksGasOnly(rawName) else { continue }

                    let coordinate = item.placemark.coordinate
                    let distance = minimumDistanceFromRoute(
                        point: coordinate,
                        route: coordinates
                    )
                    guard distance <= 3_000 else { continue }

                    let key = dedupeKey(
                        name: brand,
                        coordinate: coordinate,
                        category: .fuel
                    )
                    guard seen.insert(key).inserted else { continue }

                    let km = distance / 1000.0
                    result.append(RoutePOI(
                        id: key,
                        name: brand,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        category: .fuel,
                        distanceFromRouteKM: km,
                        estimatedDetourMinutes: estimateDetour(km)
                    ))
                }
            } catch {
                continue
            }
        }

        return spread(result, minimumSpacingMeters: 8_000, maxItems: 80)
    }

    private func localSearch(
        query: String,
        category: RoutePOICategory,
        coordinates: [OSMCoordinate],
        spacingMeters: Double,
        maxSamples: Int,
        searchRadiusMeters: Double,
        maxDistanceFromRoute: Double
    ) async -> [RoutePOI] {
        let samples = sampleByDistance(
            coordinates,
            spacingMeters: spacingMeters,
            maxCount: maxSamples
        )
        var result: [RoutePOI] = []
        var seen = Set<String>()

        for point in samples {
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            request.resultTypes = .pointOfInterest
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: point.latitude,
                    longitude: point.longitude
                ),
                latitudinalMeters: searchRadiusMeters,
                longitudinalMeters: searchRadiusMeters
            )

            do {
                let response = try await MKLocalSearch(request: request).start()
                for item in response.mapItems.prefix(8) {
                    let coordinate = item.placemark.coordinate
                    let distance = minimumDistanceFromRoute(
                        point: coordinate,
                        route: coordinates
                    )
                    guard distance <= maxDistanceFromRoute else { continue }

                    let name = item.name ?? category.title
                    let key = dedupeKey(
                        name: name,
                        coordinate: coordinate,
                        category: category
                    )
                    guard seen.insert(key).inserted else { continue }

                    let km = distance / 1000.0
                    result.append(RoutePOI(
                        id: key,
                        name: name,
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        category: category,
                        distanceFromRouteKM: km,
                        estimatedDetourMinutes: estimateDetour(km)
                    ))
                }
            } catch {
                continue
            }
        }

        let spacing: Double
        let maxItems: Int
        switch category {
        case .food:
            spacing = 20_000; maxItems = 30
        case .grocery:
            spacing = 25_000; maxItems = 25
        case .hotel:
            spacing = 35_000; maxItems = 22
        case .fuel:
            spacing = 8_000; maxItems = 80
        }
        return spread(result, minimumSpacingMeters: spacing, maxItems: maxItems)
    }

    private func recognisedFuelBrand(in value: String) -> String? {
        let n = normalize(value)
        let brands: [(String,[String])] = [
            ("Лукойл", ["лукойл","lukoil"]),
            ("Газпромнефть", ["газпромнефть","газпром нефть","gazpromneft"]),
            ("Роснефть", ["роснефть","rosneft"]),
            ("Татнефть", ["татнефть","tatneft"]),
            ("Башнефть", ["башнефть","bashneft"]),
            ("Teboil", ["teboil","тебойл"]),
            ("Нефтьмагистраль", ["нефтьмагистраль","neftmagistral"]),
            ("Трасса", ["трасса","trassa"])
        ]
        return brands.first { _, aliases in
            aliases.contains(where: { n.contains($0) })
        }?.0
    }

    private func looksGasOnly(_ value: String) -> Bool {
        let n = normalize(value)
        return ["агзс","агнкс","метан","пропан","lpg","cng","газомотор"]
            .contains(where: { n.contains($0) })
    }

    private func merge(_ a: [RoutePOI], _ b: [RoutePOI]) -> [RoutePOI] {
        var output = a
        for item in b {
            let location = CLLocation(latitude: item.latitude, longitude: item.longitude)
            let duplicate = output.contains {
                location.distance(from: CLLocation(
                    latitude: $0.latitude,
                    longitude: $0.longitude
                )) < 2_000
            }
            if !duplicate { output.append(item) }
        }
        return spread(output, minimumSpacingMeters: 8_000, maxItems: 80)
    }

    private func spread(
        _ points: [RoutePOI],
        minimumSpacingMeters: Double,
        maxItems: Int
    ) -> [RoutePOI] {
        var accepted: [RoutePOI] = []
        for point in points {
            let loc = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let close = accepted.contains {
                loc.distance(from: CLLocation(
                    latitude: $0.latitude,
                    longitude: $0.longitude
                )) < minimumSpacingMeters
            }
            if !close {
                accepted.append(point)
                if accepted.count >= maxItems { break }
            }
        }
        return accepted
    }

    private func minimumDistanceFromRoute(
        point: CLLocationCoordinate2D,
        route: [OSMCoordinate]
    ) -> Double {
        guard route.count >= 2 else { return .greatestFiniteMagnitude }

        let refLat = point.latitude * .pi / 180
        let mLat = 111_320.0
        let mLon = max(1.0, 111_320.0 * cos(refLat))

        func xy(_ c: OSMCoordinate) -> (Double,Double) {
            ((c.longitude-point.longitude)*mLon,
             (c.latitude-point.latitude)*mLat)
        }

        var best = Double.greatestFiniteMagnitude
        let step = max(1, route.count / 1500)
        var i = 0

        while i < route.count - 1 {
            let j = min(i + step, route.count - 1)
            let a = xy(route[i]), b = xy(route[j])
            let dx = b.0-a.0, dy = b.1-a.1
            let len2 = dx*dx + dy*dy
            let t = len2 > 0.0001
                ? max(0,min(1,-(a.0*dx+a.1*dy)/len2))
                : 0
            let x = a.0+t*dx, y = a.1+t*dy
            best = min(best, sqrt(x*x+y*y))
            i = j
        }
        return best
    }

    private func sampleByDistance(
        _ coordinates: [OSMCoordinate],
        spacingMeters: Double,
        maxCount: Int
    ) -> [OSMCoordinate] {
        guard coordinates.count >= 2 else { return coordinates }

        var cumulative:[Double] = [0]
        var total = 0.0
        for i in 1..<coordinates.count {
            total += distance(coordinates[i-1], coordinates[i])
            cumulative.append(total)
        }

        let count = min(maxCount, max(2, Int(total/spacingMeters)+1))
        let spacing = total / Double(max(1,count-1))
        var result:[OSMCoordinate] = []
        var idx = 0

        for n in 0..<count {
            let target = min(total,Double(n)*spacing)
            while idx < cumulative.count-2 && cumulative[idx+1] < target {
                idx += 1
            }
            let d0=cumulative[idx], d1=cumulative[min(idx+1,cumulative.count-1)]
            let a=coordinates[idx], b=coordinates[min(idx+1,coordinates.count-1)]
            let f=d1>d0 ? (target-d0)/(d1-d0) : 0
            result.append(OSMCoordinate(
                latitude:a.latitude+(b.latitude-a.latitude)*f,
                longitude:a.longitude+(b.longitude-a.longitude)*f
            ))
        }
        return result
    }

    private func distance(_ a: OSMCoordinate, _ b: OSMCoordinate) -> Double {
        CLLocation(latitude:a.latitude,longitude:a.longitude)
            .distance(from:CLLocation(latitude:b.latitude,longitude:b.longitude))
    }

    private func estimateDetour(_ km: Double) -> Int {
        max(1, Int((km/35.0*60.0+1.0).rounded(.up)))
    }

    private func dedupeKey(
        name:String,
        coordinate:CLLocationCoordinate2D,
        category:RoutePOICategory
    ) -> String {
        let lat=(coordinate.latitude*10_000).rounded()/10_000
        let lon=(coordinate.longitude*10_000).rounded()/10_000
        return "\(category.rawValue)|\(name.lowercased())|\(lat)|\(lon)"
    }

    private func normalize(_ value:String) -> String {
        value.lowercased().replacingOccurrences(of:"ё",with:"е")
    }
}
