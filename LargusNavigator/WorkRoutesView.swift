import SwiftUI

struct WorkRoutesView: View {
    @Environment(AppStore.self) private var store
    @State private var addresses = ""
    @State private var finish = "Москва, Байкальская улица, 17к1"
    @State private var route: PlannedRoute?
    @State private var selectedPOICategories: Set<RoutePOICategory> = [.fuel]
    @State private var loading = false
    @State private var errorMessage: String?
    private let planner = RoutePlanningService()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Рабочие маршруты").font(.largeTitle.bold())
                Text("Старт по умолчанию: Байкальская улица, 17к1. Вставь адреса заказов — по одному в строке. Провайдер: \(store.routingSettings.provider.rawValue).")
                    .foregroundStyle(.secondary)
                TextEditor(text: $addresses).frame(minHeight: 220).font(.body.monospaced())
                TextField("Конец маршрута", text: $finish)
                GroupBox("Что найти по маршруту") {
                    POICategoryPicker(selection: $selectedPOICategories)
                    .padding(8)
                }
                Button {
                    Task { await calculate() }
                } label: {
                    Label(loading ? "Оптимизирую…" : "Оптимизировать и рассчитать", systemImage: "arrow.triangle.swap")
                }.buttonStyle(.borderedProminent).disabled(loading || addresses.isEmpty)

                if let route {
                    HStack(spacing: 14) {
                        MetricCard(title: "Заказов", value: "\(max(0, route.orderedAddresses.count - 2))", icon: "shippingbox.fill")
                        MetricCard(title: "Пробег", value: String(format: "%.0f км", route.distanceKM), icon: "road.lanes")
                        MetricCard(title: "Время", value: String(format: "%.1f ч", route.duration / 3600), icon: "clock.fill")
                        MetricCard(title: "Бензин", value: String(format: "%.1f л", route.distanceKM * store.vehicle.averageConsumption / 100), icon: "fuelpump.fill")
                    }
                    RouteMapView()
                        .frame(minHeight: 650, idealHeight: 720)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    GroupBox("Оптимальный порядок") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(route.orderedAddresses.enumerated()), id: \.offset) { index, item in
                                Text("\(index + 1). \(item)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }.padding(28)
        }
    }

    private func calculate() async {
        loading = true
        errorMessage = nil
        store.selectedPOICategories = selectedPOICategories
        store.currentPOIs = []
        do {
            let list = addresses.split(separator: "\n").map(String.init)
            let options = try await planner.planAlternatives(
                start: "Москва, Байкальская улица, 17к1",
                waypoints: list,
                finish: finish,
                optimize: true,
                settings: store.routingSettings,
                departure: Date()
            )
            route = options.first
            store.currentRouteOptions = options
            store.selectedRouteIndex = 0
            if let first = options.first {
                store.currentFuelStations = first.provider == .yandex
                    ? ((try? await planner.fuelStations(near: first)) ?? [])
                    : []
            }
        } catch { errorMessage = error.localizedDescription }
        loading = false
    }
}
