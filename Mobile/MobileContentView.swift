import SwiftUI

struct MobileContentView: View {
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { MobileRouteView(selectedTab: $tab) }
                .tabItem { Label("Маршрут", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
                .tag(0)
            NavigationStack { MobileMapScreen() }
                .tabItem { Label("Карта", systemImage: "map.fill") }
                .tag(1)
            NavigationStack { MobileTripsView() }
                .tabItem { Label("Поездки", systemImage: "bookmark.fill") }
                .tag(2)
            NavigationStack { MobileVehicleView() }
                .tabItem { Label("Автомобиль", systemImage: "car.side.fill") }
                .tag(3)
        }
    }
}
