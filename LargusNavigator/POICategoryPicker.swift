import SwiftUI

struct POICategoryPicker: View {
    @Binding var selection: Set<RoutePOICategory>
    var showsDescription = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsDescription {
                Text("Выберите заранее — приложение найдёт только отмеченные места.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                categoryToggle(.fuel, emoji: "⛽")
                categoryToggle(.hotel, emoji: "🛏")
                categoryToggle(.food, emoji: "🍴")
                categoryToggle(.grocery, emoji: "🛒")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func categoryToggle(_ category: RoutePOICategory, emoji: String) -> some View {
#if os(macOS)
        Toggle("\(emoji) \(category.title)", isOn: Binding(
            get: { selection.contains(category) },
            set: { enabled in
                if enabled {
                    selection.insert(category)
                } else {
                    selection.remove(category)
                }
            }
        ))
        .toggleStyle(.checkbox)
#else
        Toggle("\(emoji) \(category.title)", isOn: Binding(
            get: { selection.contains(category) },
            set: { enabled in
                if enabled {
                    selection.insert(category)
                } else {
                    selection.remove(category)
                }
            }
        ))
#endif
    }
}
