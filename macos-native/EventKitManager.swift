import Foundation
import EventKit

class EventKitManager: ObservableObject {
    @Published var permissionGranted = false
    private let eventStore = EKEventStore()
    
    func requestPermission(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToReminders { granted, error in
                DispatchQueue.main.async {
                    self.permissionGranted = granted
                    completion(granted)
                }
            }
        } else {
            eventStore.requestAccess(to: .reminder) { granted, error in
                DispatchQueue.main.async {
                    self.permissionGranted = granted
                    completion(granted)
                }
            }
        }
    }
    
    func createReminders(from items: [String], listTitle: String = "EchoScribe Actions") {
        requestPermission { [weak self] granted in
            guard granted, let self = self else { return }
            
            // Check or create custom list
            let calendars = self.eventStore.calendars(for: .reminder)
            var targetCalendar: EKCalendar? = calendars.first(where: { $0.title.lowercased() == listTitle.lowercased() })
            
            if targetCalendar == nil {
                let newCalendar = EKCalendar(for: .reminder, eventStore: self.eventStore)
                newCalendar.title = listTitle
                
                // Find a default source
                if let source = self.eventStore.defaultCalendarForNewReminders()?.source {
                    newCalendar.source = source
                } else {
                    newCalendar.source = self.eventStore.sources.first(where: { $0.sourceType == .local })
                }
                
                do {
                    try self.eventStore.saveCalendar(newCalendar, commit: true)
                    targetCalendar = newCalendar
                } catch {
                    print("Failed to create reminder list: \(error.localizedDescription)")
                    targetCalendar = self.eventStore.defaultCalendarForNewReminders()
                }
            }
            
            guard let calendar = targetCalendar else { return }
            
            for item in items {
                let reminder = EKReminder(eventStore: self.eventStore)
                reminder.title = item
                reminder.calendar = calendar
                
                do {
                    try self.eventStore.save(reminder, commit: false)
                } catch {
                    print("Failed to save reminder item: \(error.localizedDescription)")
                }
            }
            
            do {
                try self.eventStore.commit()
                print("Successfully created \(items.count) reminders in list \(listTitle).")
            } catch {
                print("Failed to commit reminders to EventStore: \(error.localizedDescription)")
            }
        }
    }
}
