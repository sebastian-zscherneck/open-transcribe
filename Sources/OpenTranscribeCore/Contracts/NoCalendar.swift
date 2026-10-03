import Foundation

/// No calendar at all.
///
/// The machine this runs on keeps its appointments in Notion Calendar, which syncs Google and
/// never touches the system calendar, so EventKit could only ever return nil here — and asking
/// for calendar access to learn nothing is worse than not asking. The transcript title comes
/// from the transcript itself, and speaker names come from voice profiles after being confirmed
/// once. `CalendarContext` stays in the contract so a real source (Google, say) can be dropped
/// in without touching the daemon or the UI.
public struct NoCalendar: CalendarReading {
    public init() {}
    public func currentEvent(at date: Date) async -> CalendarContext? { nil }
}
