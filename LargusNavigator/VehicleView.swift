import SwiftUI

struct VehicleView: View {
    @Environment(AppStore.self) private var store
    @State private var savedMessage = ""

    var body: some View {
        @Bindable var store = store

        Form {
            Section("Автомобиль") {
                TextField("Название", text: $store.vehicle.name)
                TextField("Госномер", text: $store.vehicle.plate)
                TextField("VIN", text: $store.vehicle.vin)
                TextField("Двигатель", text: $store.vehicle.engine)
                Stepper("Год: \(store.vehicle.year)", value: $store.vehicle.year, in: 2000...2035)
                Stepper("Мощность: \(store.vehicle.powerHP) л.с.", value: $store.vehicle.powerHP, in: 50...300)
                Stepper("Мест: \(store.vehicle.seats)", value: $store.vehicle.seats, in: 2...9)
            }

            Section("Эксплуатация") {
                TextField("Топливо", text: $store.vehicle.fuel)
                TextField("Пробег", value: $store.vehicle.mileage, format: .number)
                TextField("Средний расход", value: $store.vehicle.averageConsumption, format: .number)
            }

            HStack {
                Button("Сохранить") {
                    store.save()
                    savedMessage = "Сохранено"
                }
                .buttonStyle(.borderedProminent)

                Text(savedMessage)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Автомобиль")
    }
}
