import SwiftUI

struct DashboardView: View {
    @Environment(AppStore.self) private var store

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
                        title: "Ближайшая поездка",
                        icon: "road.lanes"
                    ) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Москва → Волгоград")
                                .font(.title3.bold())
                            Text(
                                "М-4 → Воронеж → Анна → " +
                                "Борисоглебск → Фролово"
                            )
                            .foregroundStyle(.secondary)

                            Divider()
                            Label("≈ 1 000 км", systemImage: "arrow.left.and.right")
                            Label("≈ 13–15 часов", systemImage: "clock")
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
