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
        Button {
            if selection.contains(category) {
                selection.remove(category)
            } else {
                selection.insert(category)
            }
        } label: {
            VStack(spacing: 4) {
                Text(emoji)
                    .font(.title2)
                Text(category.title)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: selection.contains(category) ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection.contains(category) ? Color.accentColor : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 74)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(selection.contains(category) ? .accentColor : .secondary)
#endif
    }
}
