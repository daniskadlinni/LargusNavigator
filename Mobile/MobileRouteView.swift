import SwiftUI

struct MobileRouteView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTab: Int
    @State private var start = "Москва, Байкальская улица, 17к1"
    @State private var finish = ""
    @State private var waypoints = ""
    @State private var categories: Set<RoutePOICategory> = [.fuel]
    @State private var loading = false
    @State private var errorMessage = ""
    private let planner = RoutePlanningService()

    var body: some View {
        Form {
            Section("Куда едем") {
                TextField("Старт", text: $start)
                TextField("Финиш", text: $finish)
                TextField("Промежуточные точки через запятую", text: $waypoints, axis: .vertical)
            }
            Section("Что найти") {
                POICategoryPicker(selection: $categories, showsDescription: false)
            }
            Section {
                Button {
                    Task { await calculate() }
                } label: {
                    Label(loading ? "Строю маршрут…" : "Построить маршрут", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(loading || finish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !errorMessage.isEmpty {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Новый маршрут")
    }

    @MainActor
    private func calculate() async {
        loading = true
        errorMessage = ""
        defer { loading = false }
        do {
            var settings = store.routingSettings
            settings.provider = .osm
            settings.alternativeCount = 3
            let points = waypoints.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let routes = try await planner.planAlternatives(
                start: start,
                waypoints: points,
                finish: finish,
                optimize: false,
                settings: settings,
                departure: Date()
            )
            store.currentRouteOptions = routes
            store.selectedRouteIndex = 0
            store.selectedPOICategories = categories
            store.currentPOIs = []
            store.recommendedFuelStops = []
            selectedTab = 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
