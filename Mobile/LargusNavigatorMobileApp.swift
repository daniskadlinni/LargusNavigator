import SwiftUI

@main
struct LargusNavigatorMobileApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            MobileContentView()
                .environment(store)
        }
    }
}
