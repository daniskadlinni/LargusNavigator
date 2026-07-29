import SwiftUI

struct TripsHistoryView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Сохранённые поездки").font(.largeTitle.bold())
            if store.trips.isEmpty {
                ContentUnavailableView("Поездок пока нет", systemImage: "tent.fill", description: Text("Создай маршрут во вкладке «Путешествия и рыбалка»."))
            } else {
                List {
                    ForEach(store.trips) { trip in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(trip.title).font(.headline)
                                Spacer()
                                Text(trip.kind).foregroundStyle(.secondary)
                            }
                            Text("\(trip.start) → \(trip.finish)").lineLimit(1)
                            Text(String(format: "%.0f км · %.1f л · %.0f ₽", trip.distanceKM, trip.fuelLiters, trip.fuelCost))
                                .foregroundStyle(.secondary)
                            ProgressView(value: Double(trip.checklist.filter(\.isDone).count), total: Double(max(1, trip.checklist.count)))
                        }.padding(.vertical, 5)
                    }.onDelete(perform: store.deleteTrips)
                }
            }
        }.padding(28)
    }
}
