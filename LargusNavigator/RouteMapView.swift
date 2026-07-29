import SwiftUI
import MapKit

struct RouteMapView: View {
    @Environment(AppStore.self) private var store
    @State private var position: MapCameraPosition = .automatic
    @State private var showFuel = true
    @State private var showHotels = true
    @State private var showFood = true
    @State private var showGroceries = true
    @State private var poiLoadSerial = 0
    @State private var fuelStatus = "—"
    @State private var hotelStatus = "—"
    @State private var foodStatus = "—"
    @State private var groceryStatus = "—"
    @State private var fuelDiagnostics = "Поиск АЗС ещё не запускался"
    @State private var fuelCoverageIsUseful = false
    @State private var routePOICache: [UUID: CachedRoutePOIs] = [:]

    private var selectedRoute: PlannedRoute? {
        guard store.currentRouteOptions.indices.contains(store.selectedRouteIndex) else { return nil }
        return store.currentRouteOptions[store.selectedRouteIndex]
    }

    private var yandexKey: String { KeychainStore.yandexAPIKey() }

    var body: some View {
        VStack(spacing: 0) {
            if store.currentRouteOptions.isEmpty {
                ContentUnavailableView(
                    "Маршрут ещё не рассчитан",
                    systemImage: "map",
                    description: Text("Откройте «Путешествия и рыбалка» или «Рабочие маршруты» и рассчитайте маршрут.")
                )
            } else {
                routeSelector
                poiLayerControls
                fuelDiagnosticsBanner

                if selectedRoute?.provider == .osm {
                    OpenStreetMapView(
                            options: store.currentRouteOptions,
                            selectedIndex: store.selectedRouteIndex,
                            pois: store.currentPOIs,
                            showFuel: showFuel,
                            showHotels: showHotels,
                            showFood: showFood,
                            showGroceries: showGroceries
                    )
                } else if selectedRoute?.provider == .yandex, !yandexKey.isEmpty {
                    YandexEmbeddedMapView(
                        options: store.currentRouteOptions,
                        selectedIndex: store.selectedRouteIndex,
                        apiKey: yandexKey,
                        fuelStations: store.currentFuelStations
                    )
                } else {
                    appleMap
                }
            }
        }
        .navigationTitle(selectedRoute?.provider == .osm ? "OpenStreetMap — маршруты" : (selectedRoute?.provider == .yandex ? "Яндекс.Карта маршрута" : "Карта маршрута"))
        .task(id: selectedRoute?.id) {
            await reloadPOIs()
        }
    }

    private var routeSelector: some View {
        HStack(spacing: 10) {
            ForEach(Array(store.currentRouteOptions.enumerated()), id: \.element.id) { index, route in
                Button {
                    store.selectedRouteIndex = index
                    position = .automatic
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(routeColor(index))
                                .frame(width: 9, height: 9)
                            Text(routeDisplayName(route, index: index)).font(.headline)
                            Text(route.provider.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(String(format: "%.0f км · %@", route.distanceKM, durationText(route.duration)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .tint(index == store.selectedRouteIndex ? routeColor(index) : .gray)
            }
            Spacer()
        }
        .padding(12)
    }


    private var poiLayerControls: some View {
        HStack(spacing: 14) {
            Text("На карте:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("⛽ АЗС \(fuelStatus)", isOn: $showFuel)
                .toggleStyle(.checkbox)
            Toggle("🛏 Отели \(hotelStatus)", isOn: $showHotels)
                .toggleStyle(.checkbox)
            Toggle("🍴 Поесть \(foodStatus)", isOn: $showFood)
                .toggleStyle(.checkbox)
            Toggle("🛒 Продукты \(groceryStatus)", isOn: $showGroceries)
                .toggleStyle(.checkbox)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var fuelDiagnosticsBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: fuelCoverageIsUseful ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(fuelCoverageIsUseful ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Покрытие АЗС")
                    .font(.caption.bold())
                Text(fuelDiagnostics)
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                if !fuelCoverageIsUseful, fuelStatus != "ищу…" {
                    Text("Есть крупный участок маршрута без подтверждённых АЗС.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background((fuelCoverageIsUseful ? Color.green : Color.orange).opacity(0.10))
    }

    private var visiblePOICount: Int {
        store.currentPOIs.filter { poi in
            switch poi.category {
            case .fuel: showFuel
            case .hotel: showHotels
            case .food: showFood
            case .grocery: showGroceries
            }
        }.count
    }

    private var appleMap: some View {
        Map(position: $position) {
            ForEach(Array(store.currentRouteOptions.enumerated()), id: \.element.id) { index, option in
                ForEach(Array(option.pathCoordinates.enumerated()), id: \.offset) { _, coordinates in
                    if coordinates.count >= 2 {
                        MapPolyline(coordinates: coordinates)
                            .stroke(
                                routeColor(index).opacity(index == store.selectedRouteIndex ? 1.0 : 0.55),
                                style: StrokeStyle(
                                    lineWidth: index == store.selectedRouteIndex ? 7 : 3,
                                    lineCap: .round,
                                    lineJoin: .round,
                                    dash: index == store.selectedRouteIndex ? [] : [10, 7]
                                )
                            )
                    }
                }
            }

            if let route = selectedRoute {
                ForEach(Array(route.mapItems.enumerated()), id: \.offset) { index, item in
                    Marker(
                        index == 0 ? "Старт" : (index == route.mapItems.count - 1 ? "Финиш" : (item.name ?? "Точка")),
                        systemImage: index == 0 ? "car.fill" : (index == route.mapItems.count - 1 ? "flag.checkered" : "mappin.circle.fill"),
                        coordinate: item.placemark.coordinate
                    )
                }
            }

            ForEach(store.currentPOIs.filter { poiVisible($0.category) }) { poi in
                Marker(
                    poi.name,
                    systemImage: poi.category.symbol,
                    coordinate: CLLocationCoordinate2D(latitude: poi.latitude, longitude: poi.longitude)
                )
                .tint(poiColor(poi.category))
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapScaleView()
            MapZoomStepper()
        }
    }



    @MainActor
    private func reloadPOIs() async {
        guard let route = selectedRoute else { return }

        if let cached = routePOICache[route.id] {
            store.currentPOIs = cached.points
            fuelStatus = cached.status(for: .fuel)
            hotelStatus = cached.status(for: .hotel)
            foodStatus = cached.status(for: .food)
            groceryStatus = cached.status(for: .grocery)
            fuelDiagnostics = cached.fuelDiagnostics
            fuelCoverageIsUseful = cached.fuelCoverageIsUseful
            return
        }

        poiLoadSerial += 1
        let serial = poiLoadSerial
        let routeID = route.id
        let safeCoordinates = route.coordinates.map {
            OSMCoordinate(latitude: $0.latitude, longitude: $0.longitude)
        }

        store.currentPOIs = []
        fuelStatus = "ищу…"
        fuelDiagnostics = "Ищу АЗС по всему маршруту…"
        fuelCoverageIsUseful = false
        hotelStatus = "ищу…"
        foodStatus = "ищу…"
        groceryStatus = "ищу…"

        await withTaskGroup(of: POILoadResult.self) { group in
            for category in RoutePOICategory.allCases {
                group.addTask {
                    let points = await ApplePOIService.shared.points(
                        for: category,
                        coordinates: safeCoordinates
                    )
                    return POILoadResult(category: category, points: points)
                }
            }

            for await result in group {
                guard serial == poiLoadSerial,
                      selectedRoute?.id == routeID
                else {
                    group.cancelAll()
                    return
                }

                // Replace only this category. Other completed categories stay visible.
                store.currentPOIs.removeAll { $0.category == result.category }
                store.currentPOIs.append(contentsOf: result.points)
                setStatus(result.points.count, for: result.category)
                if result.category == .fuel {
                    fuelDiagnostics = StableFuelService.shared.lastDiagnostics
                    fuelCoverageIsUseful = StableFuelService.shared.lastCoverageIsUseful
                }
            }
        }

        // A task can be cancelled before all four statuses are completed.
        if serial == poiLoadSerial, selectedRoute?.id == routeID {
            if fuelStatus == "ищу…" { fuelStatus = "0" }
            if hotelStatus == "ищу…" { hotelStatus = "0" }
            if foodStatus == "ищу…" { foodStatus = "0" }
            if groceryStatus == "ищу…" { groceryStatus = "0" }

            routePOICache[routeID] = CachedRoutePOIs(
                points: store.currentPOIs,
                fuelDiagnostics: fuelDiagnostics,
                fuelCoverageIsUseful: fuelCoverageIsUseful
            )
        }
    }

    @MainActor
    private func setStatus(_ count: Int, for category: RoutePOICategory) {
        let text = "\(count)"
        switch category {
        case .fuel: fuelStatus = text
        case .hotel: hotelStatus = text
        case .food: foodStatus = text
        case .grocery: groceryStatus = text
        }
    }

    private func poiVisible(_ category: RoutePOICategory) -> Bool {
        switch category {
        case .fuel: showFuel
        case .hotel: showHotels
        case .food: showFood
        case .grocery: showGroceries
        }
    }

    private func poiColor(_ category: RoutePOICategory) -> Color {
        switch category {
        case .fuel: .orange
        case .hotel: .purple
        case .food: .red
        case .grocery: .green
        }
    }

    private func routeDisplayName(_ route: PlannedRoute, index: Int) -> String {
        if let first = route.orderedAddresses.first, first.hasPrefix("Сценарий: ") {
            return first.replacingOccurrences(of: "Сценарий: ", with: "")
        }
        return index == 0 ? "Маршрут 1" : "Маршрут \(index + 1)"
    }

    private func routeColor(_ index: Int) -> Color {
        switch index % 3 {
        case 0: .green   // Основная
        case 1: .red     // Альтернативная
        default: .blue   // Дополнительная
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return "\(hours) ч \(minutes) мин"
    }
}


private struct POILoadResult: Sendable {
    let category: RoutePOICategory
    let points: [RoutePOI]
}

private struct CachedRoutePOIs {
    let points: [RoutePOI]
    let fuelDiagnostics: String
    let fuelCoverageIsUseful: Bool

    func status(for category: RoutePOICategory) -> String {
        "\(points.lazy.filter { $0.category == category }.count)"
    }
}
