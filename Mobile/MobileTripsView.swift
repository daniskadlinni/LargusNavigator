import SwiftUI

struct MobileTripsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            if store.trips.isEmpty {
                ContentUnavailableView("Поездок пока нет", systemImage: "bookmark", description: Text("Сохранённые на Mac поездки появятся здесь через iCloud."))
            } else {
                ForEach(store.trips) { trip in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(trip.title).font(.headline)
                        Text("\(trip.start) → \(trip.finish)").lineLimit(2)
                        Text(trip.departure.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.0f км · %.0f ₽", trip.distanceKM, trip.fuelCost))
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: store.deleteTrips)
            }
        }
        .navigationTitle("Поездки")
    }
}
