import SwiftUI

struct DashboardView: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: SidebarItem?

    private var nextTrip: SavedTrip? {
        let now = Calendar.current.startOfDay(for: Date())
        return store.trips
            .filter { $0.departure >= now }
            .min { $0.departure < $1.departure }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.vehicle.name.uppercased())
                            .font(.system(
                                size: 34,
                                weight: .heavy,
                                design: .rounded
                            ))

                        Text(
                            "\(store.vehicle.year) · " +
                            "\(store.vehicle.engine) · " +
                            "\(store.vehicle.powerHP) л.с. · " +
                            "\(store.vehicle.seats) мест"
                        )
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "car.side.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.tint)
                }

                HStack(spacing: 16) {
                    MetricCard(
                        title: "Пробег",
                        value: "\(store.vehicle.mileage) км",
                        icon: "gauge.with.dots.needle.50percent"
                    )
                    MetricCard(
                        title: "Средний расход",
                        value: String(
                            format: "%.1f л/100",
                            store.vehicle.averageConsumption
                        ),
                        icon: "fuelpump.fill"
                    )
                    MetricCard(
                        title: "Топливо",
                        value: store.vehicle.fuel,
                        icon: "drop.fill"
                    )
                    MetricCard(
                        title: "Следующее ТО",
                        value: "\(store.nextServiceMileage) км",
                        icon: "wrench.fill"
                    )
                }

                HStack(alignment: .top, spacing: 18) {
                    DashboardPanel(
                        title: nextTrip == nil ? "Новая поездка" : "Ближайшая поездка",
                        icon: "road.lanes"
                    ) {
                        if let trip = nextTrip {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(trip.title)
                                    .font(.title3.bold())
                                Text("\(trip.start) → \(trip.finish)")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                Divider()
                                Label(trip.departure.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                                Label(String(format: "%.0f км · %.0f ₽", trip.distanceKM, trip.fuelCost), systemImage: "arrow.left.and.right")
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Сохранённых будущих поездок пока нет.")
                                    .foregroundStyle(.secondary)
                                Button {
                                    selection = .travel
                                } label: {
                                    Label("Построить маршрут", systemImage: "plus.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }

                    DashboardPanel(
                        title: "Перед стартом",
                        icon: "checklist"
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            CheckRow(text: "Масло и антифриз")
                            CheckRow(text: "Давление в шинах")
                            CheckRow(text: "АИ-95 и запас хода")
                            CheckRow(text: "Документы, компрессор, трос")
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button { selection = .travel } label: {
                        Label("Путешествие", systemImage: SidebarItem.travel.icon)
                    }
                    Button { selection = .work } label: {
                        Label("Рабочий маршрут", systemImage: SidebarItem.work.icon)
                    }
                    Button { selection = .expenses } label: {
                        Label("Расходы", systemImage: SidebarItem.expenses.icon)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(28)
        }
        .navigationTitle("Главная")
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
            Text(value)
                .font(.title2.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 18)
        )
    }
}

struct DashboardPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: icon)
                .font(.headline)
            content
        }
        .padding(20)
        .frame(
            maxWidth: .infinity,
            minHeight: 230,
            alignment: .topLeading
        )
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 20)
        )
    }
}

struct CheckRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle")
    }
}
