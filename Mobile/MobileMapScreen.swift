import SwiftUI
import MapKit

struct MobileMapScreen: View {
    @Environment(AppStore.self) private var store
    @State private var position: MapCameraPosition = .automatic
    @State private var loading = false
    @State private var progress = FuelSearchProgress()
    @State private var errorMessage = ""

    private var route: PlannedRoute? {
        guard store.currentRouteOptions.indices.contains(store.selectedRouteIndex) else { return nil }
        return store.currentRouteOptions[store.selectedRouteIndex]
    }

    var body: some View {
        Group {
            if let route {
                ZStack(alignment: .bottom) {
                    Map(position: $position) {
                        ForEach(Array(store.currentRouteOptions.enumerated()), id: \.element.id) { index, option in
                            ForEach(Array(option.pathCoordinates.enumerated()), id: \.offset) { _, segment in
                                if segment.count >= 2 {
                                    MapPolyline(coordinates: segment)
                                        .stroke(index == store.selectedRouteIndex ? .blue : .gray.opacity(0.45), lineWidth: index == store.selectedRouteIndex ? 6 : 3)
                                }
                            }
                        }
                        ForEach(store.currentPOIs) { poi in
                            Marker(poi.name, systemImage: "fuelpump.fill", coordinate: CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude))
                                .tint(store.recommendedFuelStops.contains(where: { $0.station.id == poi.id }) ? .green : .orange)
                        }
                    }
                    .mapControls { MapCompass(); MapScaleView(); MapUserLocationButton() }

                    VStack(alignment: .leading, spacing: 10) {
                        if loading {
                            ProgressView(value: progress.fraction) {
                                Text("АЗС: \(progress.checkedSections) из \(progress.totalSections) участков")
                            }
                        }
                        Text(String(format: "%.0f км · %@", route.distanceKM, duration(route.duration)))
                            .font(.headline)
                        if store.recommendedFuelStops.isEmpty {
                            Text(loading ? "Ищу подходящие заправки…" : "Рекомендованных остановок нет")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(store.recommendedFuelStops) { stop in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(stop.station.name).font(.headline)
                                            Text(stop.station.roadKilometerLabel ?? String(format: "%.0f км маршрута", stop.station.routeProgressKM ?? 0))
                                            Text(stop.station.routeSide.title).foregroundStyle(.secondary)
                                        }
                                        .padding(10)
                                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    .padding()
                }
                .task(id: route.id) { await loadPOIs(route) }
            } else {
                ContentUnavailableView("Маршрут не построен", systemImage: "map", description: Text("Сначала задайте маршрут на первой вкладке."))
            }
        }
        .navigationTitle("Карта")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func loadPOIs(_ route: PlannedRoute) async {
        loading = true
        errorMessage = ""
        let coordinates = route.coordinates.map { OSMCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        let points = await ApplePOIService.shared.points(for: .fuel, coordinates: coordinates) { value in
            await MainActor.run { progress = value }
        }
        store.currentPOIs = points
        store.recommendedFuelStops = FuelStopPlanner.recommendations(
            stations: points,
            routeLengthKM: route.distanceKM,
            vehicle: store.vehicle,
            settings: store.fuelPlanningSettings
        )
        store.currentFuelGaps = FuelCoverageAnalyzer.gaps(stations: points, route: route.coordinates)
        loading = false
    }

    private func duration(_ seconds: TimeInterval) -> String {
        "\(Int(seconds) / 3600) ч \((Int(seconds) % 3600) / 60) мин"
    }
}
