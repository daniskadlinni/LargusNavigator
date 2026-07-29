import SwiftUI

struct ServiceView: View {
    @Environment(AppStore.self) private var store
    @State private var showingEditor = false

    var body: some View {
        VStack {
            if store.services.isEmpty {
                ContentUnavailableView(
                    "Записей ТО пока нет",
                    systemImage: "wrench.and.screwdriver",
                    description: Text("Добавь первое обслуживание Ларгуса.")
                )
            } else {
                List {
                    ForEach(store.services) { record in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(record.title).font(.headline)
                                Text(record.details).foregroundStyle(.secondary)
                                Text(record.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                Text("\(record.mileage) км").monospacedDigit()
                                Text(record.cost.formatted(.currency(code: "RUB")))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: store.deleteServices)
                }
            }
        }
        .navigationTitle("ТО и ремонты")
        .toolbar {
            Button {
                showingEditor = true
            } label: {
                Label("Добавить", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingEditor) {
            ServiceEditor()
        }
    }
}

private struct ServiceEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var title = "ТО после обкатки"
    @State private var mileage = 2000
    @State private var details = "Масло и фильтр"
    @State private var cost = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новое обслуживание").font(.title2.bold())
            DatePicker("Дата", selection: $date, displayedComponents: .date)
            TextField("Название", text: $title)
            TextField("Пробег", value: $mileage, format: .number)
            TextField("Описание", text: $details)
            TextField("Стоимость", value: $cost, format: .number)

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    store.addService(ServiceRecord(
                        date: date,
                        mileage: mileage,
                        title: title,
                        details: details,
                        cost: cost
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 450)
    }
}
