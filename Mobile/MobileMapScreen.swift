import SwiftUI
import MapKit

struct MobileMapScreen: View {
    @Environment(AppStore.self) private var store
    @State private var position: MapCameraPosition = .automatic
    @State private var loading = false
    @State private var progress = FuelSearchProgress()
    @State private var errorMessage = ""
    @State private var resultsPanelVisible = true
    @StateObject private var locationManager = MobileLocationManager()

    private var route: PlannedRoute? {
        guard store.currentRouteOptions.indices.contains(store.selectedRouteIndex) else { return nil }
        return store.currentRouteOptions[store.selectedRouteIndex]
    }

    var body: some View {
        Group {
            if let route {
                ZStack(alignment: .bottom) {
                    Map(position: $position) {
                        UserAnnotation()
                        ForEach(Array(store.currentRouteOptions.enumerated()), id: \.element.id) { index, option in
                            ForEach(Array(option.pathCoordinates.enumerated()), id: \.offset) { _, segment in
                                if segment.count >= 2 {
                                    MapPolyline(coordinates: segment)
                                        .stroke(index == store.selectedRouteIndex ? .blue : .gray.opacity(0.45), lineWidth: index == store.selectedRouteIndex ? 6 : 3)
                                }
                            }
                        }
                        ForEach(store.currentPOIs) { poi in
                            Marker(poi.name, systemImage: poi.category.symbol, coordinate: CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude))
                                .tint(store.recommendedFuelStops.contains(where: { $0.station.id == poi.id }) ? .green : .orange)
                        }
                    }
                    .mapControls { MapCompass(); MapScaleView(); MapUserLocationButton() }

                    if resultsPanelVisible {
                        resultsPanel(route)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        Button {
                            withAnimation { resultsPanelVisible = true }
                        } label: {
                            Label("Показать результаты", systemImage: "chevron.up")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 10)
                    }
                }
                .animation(.snappy, value: resultsPanelVisible)
                .task(id: route.id) {
                    resultsPanelVisible = true
                    locationManager.requestLocation()
                    await loadPOIs(route)
                }
                .onChange(of: locationManager.location) { _, location in
                    guard let location else { return }
                    position = .region(MKCoordinateRegion(
                        center: location.coordinate,
                        latitudinalMeters: 20_000,
                        longitudinalMeters: 20_000
                    ))
                }
            } else {
                ContentUnavailableView("Маршрут не построен", systemImage: "map", description: Text("Сначала задайте маршрут на первой вкладке."))
            }
        }
        .navigationTitle("Карта")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func resultsPanel(_ route: PlannedRoute) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Capsule()
                .fill(.secondary.opacity(0.55))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
            if loading {
                ProgressView(value: progress.fraction) {
                    Text("Поиск: \(progress.checkedSections) из \(progress.totalSections) участков")
                        .font(.caption2)
                }
            }
            Text(String(format: "%.0f км · %@", route.distanceKM, duration(route.duration)))
                .font(.subheadline.weight(.semibold))
            if store.recommendedFuelStops.isEmpty {
                Text(loading ? "Ищу выбранные точки…" : "Рекомендованных остановок нет")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(store.recommendedFuelStops) { stop in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stop.station.name).font(.caption.weight(.semibold))
                                Text(stop.station.roadKilometerLabel ?? String(format: "%.0f км маршрута", stop.station.routeProgressKM ?? 0))
                                Text(stop.station.routeSide.title).foregroundStyle(.secondary)
                            }
                            .font(.caption2)
                            .padding(8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            Text("Смахните панель вниз, чтобы освободить карту")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(11)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(8)
        .gesture(DragGesture(minimumDistance: 15).onEnded { value in
            if value.translation.height > 55 {
                withAnimation { resultsPanelVisible = false }
            }
        })
    }

    @MainActor
    private func loadPOIs(_ route: PlannedRoute) async {
        loading = true
        errorMessage = ""
        let coordinates = route.coordinates.map { OSMCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        var points: [RoutePOI] = []
        for category in store.selectedPOICategories {
            let found = await ApplePOIService.shared.points(
                for: category,
                coordinates: coordinates,
                fuelProgress: category == .fuel ? { value in
                    await MainActor.run { progress = value }
                } : nil
            )
            points.append(contentsOf: found)
        }
        store.currentPOIs = points
        let fuelPoints = points.filter { $0.category == .fuel }
        store.recommendedFuelStops = FuelStopPlanner.recommendations(
            stations: fuelPoints,
            routeLengthKM: route.distanceKM,
            vehicle: store.vehicle,
            settings: store.fuelPlanningSettings
        )
        store.currentFuelGaps = FuelCoverageAnalyzer.gaps(stations: fuelPoints, route: route.coordinates)
        loading = false
    }

    private func duration(_ seconds: TimeInterval) -> String {
        "\(Int(seconds) / 3600) ч \((Int(seconds) % 3600) / 60) мин"
    }
}
