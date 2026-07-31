import Foundation

struct RecommendedFuelStop: Identifiable, Equatable, Sendable {
    let station: RoutePOI
    let arrivalRangeRemainingKM: Double
    let reason: String

    var id: String { station.id }
}

enum FuelStopPlanner {
    static func recommendations(
        stations: [RoutePOI],
        routeLengthKM: Double,
        vehicle: Vehicle,
        settings: FuelPlanningSettings
    ) -> [RecommendedFuelStop] {
        guard routeLengthKM > 0,
              vehicle.averageConsumption > 0,
              vehicle.tankCapacityLiters > settings.minimumReserveLiters
        else { return [] }

        let startingLiters = vehicle.tankCapacityLiters
            * min(100, max(0, settings.startFuelPercent)) / 100
        let firstSafeRange = max(0, startingLiters - settings.minimumReserveLiters)
            / vehicle.averageConsumption * 100
        let fullSafeRange = (vehicle.tankCapacityLiters - settings.minimumReserveLiters)
            / vehicle.averageConsumption * 100
        guard fullSafeRange > 40 else { return [] }

        let candidates = stations
            .filter { $0.category == .fuel && $0.routeProgressKM != nil }
            .sorted { ($0.routeProgressKM ?? 0) < ($1.routeProgressKM ?? 0) }

        var result: [RecommendedFuelStop] = []
        var currentKM = 0.0
        var safeRange = firstSafeRange

        while currentKM + safeRange < routeLengthKM,
              result.count < settings.maximumRecommendedStops {
            let latestSafeKM = currentKM + safeRange
            let targetKM = currentKM + safeRange * 0.78
            let windowStart = currentKM + max(35, safeRange * 0.45)
            let available = candidates.filter { station in
                guard let km = station.routeProgressKM else { return false }
                return km > windowStart && km <= latestSafeKM
                    && !result.contains(where: { $0.station.id == station.id })
            }

            guard let chosen = available.min(by: {
                score($0, targetKM: targetKM, settings: settings)
                    < score($1, targetKM: targetKM, settings: settings)
            }), let chosenKM = chosen.routeProgressKM else {
                break
            }

            let travelled = chosenKM - currentKM
            result.append(RecommendedFuelStop(
                station: chosen,
                arrivalRangeRemainingKM: max(0, safeRange - travelled),
                reason: settings.preferredNetworks.contains(chosen.name)
                    ? "предпочитаемая сеть перед исчерпанием запаса хода"
                    : "закрывает участок без подходящей сетевой АЗС"
            ))
            currentKM = chosenKM
            safeRange = fullSafeRange
        }
        return result
    }

    private static func score(
        _ station: RoutePOI,
        targetKM: Double,
        settings: FuelPlanningSettings
    ) -> Double {
        let distancePenalty = abs((station.routeProgressKM ?? targetKM) - targetKM)
        let networkBonus = settings.preferredNetworks.contains(station.name) ? -45.0 : 0
        let sideBonus = settings.preferSameSide && station.routeSide == .right ? -12.0 : 0
        let detourPenalty = Double(station.estimatedDetourMinutes) * 2.5
        return distancePenalty + networkBonus + sideBonus + detourPenalty
    }
}
