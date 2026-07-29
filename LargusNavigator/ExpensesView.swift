import SwiftUI

struct ExpensesView: View {
    @Environment(AppStore.self) private var store
    @State private var showingEditor = false

    var body: some View {
        VStack {
            if store.expenses.isEmpty {
                ContentUnavailableView(
                    "Расходов пока нет",
                    systemImage: "rublesign.circle",
                    description: Text("Здесь будут топливо, платные дороги и ТО.")
                )
            } else {
                List {
                    ForEach(store.expenses) { expense in
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(expense.category).font(.headline)
                                Text(expense.details).foregroundStyle(.secondary)
                                Text(expense.date.formatted(date: .abbreviated, time: .omitted))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(expense.amount.formatted(.currency(code: "RUB")))
                                .font(.headline)
                        }
                        .padding(.vertical, 4)
                    }
                    .onDelete(perform: store.deleteExpenses)
                }

                HStack {
                    Text("Итого").font(.headline)
                    Spacer()
                    Text(store.totalExpenses.formatted(.currency(code: "RUB")))
                        .font(.title3.bold())
                }
                .padding()
            }
        }
        .navigationTitle("Расходы")
        .toolbar {
            Button {
                showingEditor = true
            } label: {
                Label("Добавить", systemImage: "plus")
            }
        }
        .sheet(isPresented: $showingEditor) {
            ExpenseEditor()
        }
    }
}

private struct ExpenseEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var date = Date()
    @State private var category = "Топливо"
    @State private var details = "АИ-95"
    @State private var amount = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новый расход").font(.title2.bold())
            DatePicker("Дата", selection: $date, displayedComponents: .date)
            Picker("Категория", selection: $category) {
                ForEach(["Топливо", "ТО и ремонт", "Платная дорога", "Страховка", "Мойка", "Другое"], id: \.self) {
                    Text($0)
                }
            }
            TextField("Описание", text: $details)
            TextField("Сумма", value: $amount, format: .number)

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    store.addExpense(ExpenseRecord(
                        date: date,
                        category: category,
                        amount: amount,
                        details: details
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(amount <= 0)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24)
        .frame(width: 450)
    }
}
