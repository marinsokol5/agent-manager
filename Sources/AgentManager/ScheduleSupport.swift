import AgentManagerCore
import Foundation
import SwiftUI

/// Local-time helpers shared by the journey-4 screens.
enum WeekTime {
    /// Today as 0 = Mon .. 6 = Sun (the schedule/engine convention).
    static var todayMon0: Int { (Calendar.current.component(.weekday, from: Date()) + 5) % 7 }

    /// Minutes-from-midnight right now.
    static var nowMinutes: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

extension AppModel {
    /// `accountID → swatch` for the connected accounts the planner schedules.
    var scheduledAccountColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: scheduledAccounts.map { ($0.id, Color(hex: $0.color)) })
    }
}
