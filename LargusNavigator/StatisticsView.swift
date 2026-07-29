import SwiftUI

struct StatisticsView: View {
    @Environment(AppStore.self) private var store

    private var tripKM: Double { store.trips.reduce(0) { $0 + $1.distanceKM } }
    private var tripFuel: Double { store.trips.reduce(0) { $0 + $1.fuelLiters } }
    private var tripCost: Double { store.trips.reduce(0) { $0 + $1.fuelCost } }
    private var serviceCost: Double { store.services.reduce(0) { $0 + $1.cost } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Статистика").font(.largeTitle.bold())
                HStack(spacing: 14) {
                    MetricCard(title: "Пробег поездок", value: String(format: "%.0f км", tripKM), icon: "road.lanes")
                    MetricCard(title: "Топливо поездок", value: String(format: "%.1f л", tripFuel), icon: "fuelpump.fill")
                    MetricCard(title: "Расходы поездок", value: String(format: "%.0f ₽", tripCost), icon: "rublesign.circle.fill")
                }
                HStack(spacing: 14) {
                    MetricCard(title: "Все расходы", value: String(format: "%.0f ₽", store.totalExpenses), icon: "creditcard.fill")
                    MetricCard(title: "ТО и ремонты", value: String(format: "%.0f ₽", serviceCost), icon: "wrench.and.screwdriver.fill")
                    MetricCard(title: "До ТО", value: "\(max(0, store.nextServiceMileage - store.vehicle.mileage)) км", icon: "gauge.with.dots.needle.50percent")
                }
                GroupBox("Итог использования") {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("Сохранено поездок", value: "\(store.trips.count)")
                        LabeledContent("Записей ТО", value: "\(store.services.count)")
                        LabeledContent("Записей расходов", value: "\(store.expenses.count)")
                        LabeledContent("Средний расход", value: String(format: "%.1f л/100 км", store.vehicle.averageConsumption))
                    }.padding(8)
                }
            }.padding(28)
        }
    }
}
