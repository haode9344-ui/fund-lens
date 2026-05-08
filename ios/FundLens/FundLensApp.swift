import CoreData
import SwiftUI

@main
struct FundLensApp: App {
    init() {
        NotificationService.shared.requestAuthorization()
        NotificationService.shared.scheduleTradingReminders()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, CoreDataStore.shared.context)
        }
    }
}
