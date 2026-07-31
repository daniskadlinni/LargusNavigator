import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case dashboard = "Главная"
    case work = "Рабочие маршруты"
    case travel = "Путешествия и рыбалка"
    case trips = "Сохранённые поездки"
    case vehicle = "Автомобиль"
    case service = "ТО и ремонты"
    case expenses = "Расходы"
    case statistics = "Статистика"
    case routing = "Маршрутизация"
    case update = "Обновление и данные"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2.fill"
        case .work: "shippingbox.and.arrow.backward.fill"
        case .travel: "tent.fill"
        case .trips: "bookmark.fill"
        case .vehicle: "car.side.fill"
        case .service: "wrench.and.screwdriver.fill"
        case .expenses: "rublesign.circle.fill"
        case .statistics: "chart.bar.xaxis"
        case .routing: "point.topleft.down.to.point.bottomright.curvepath"
        case .update: "arrow.triangle.2.circlepath.circle.fill"
        }
    }
}

struct ContentView: View {
    @State private var selection: SidebarItem? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Маршруты") {
                    sidebarRow(.dashboard)
                    sidebarRow(.travel)
                    sidebarRow(.work)
                    sidebarRow(.trips)
                }

                Section("Автомобиль") {
                    sidebarRow(.vehicle)
                    sidebarRow(.service)
                    sidebarRow(.expenses)
                    sidebarRow(.statistics)
                }

                Section("Настройки") {
                    sidebarRow(.routing)
                    sidebarRow(.update)
                }
            }
            .navigationTitle("Largus Navigator")
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard: DashboardView(selection: $selection)
            case .work: WorkRoutesView()
            case .travel: TravelPlannerView()
            case .trips: TripsHistoryView()
            case .vehicle: VehicleView()
            case .service: ServiceView()
            case .expenses: ExpensesView()
            case .statistics: StatisticsView()
            case .routing: RoutingSettingsView()
            case .update: UpdateView()
            }
        }
    }

    private func sidebarRow(_ item: SidebarItem) -> some View {
        Label(item.rawValue, systemImage: item.icon)
            .tag(item)
            .padding(.vertical, 4)
    }
}
