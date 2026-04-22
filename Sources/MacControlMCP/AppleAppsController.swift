import Foundation
#if canImport(EventKit)
import EventKit
#endif

/// Native Apple-app automation: Messages, Mail, Calendar, Reminders, Contacts.
///
/// All operations go through AppleScript via `OsascriptRunner`.  The first
/// call to each app triggers the one-time macOS Automation permission
/// dialog — agents calling these tools should expect a permission prompt
/// the first time (Apple's TCC system, no way around it programmatically
/// without special entitlements).
///
/// Why AppleScript instead of EventKit / MessageKit / ContactsKit? Those
/// require bundled entitlements + code signing with a paid developer team
/// AND a fresh user-consent flow for each framework. The MCP already has
/// `NSAppleEventsUsageDescription` set up for osascript, so piggy-backing
/// on that keeps the install story simple.
///
/// Codex v0.5.0 hardening: every method returns a structured result with
/// `ok:false + error:<stderr>` when AppleScript fails (syntax errors,
/// permission denials, bad email addresses, etc.) — no silent-success.
actor AppleAppsController {

    /// Uniform envelope for app-automation results.
    public struct Result<T: Codable & Sendable>: Codable, Sendable {
        public let ok: Bool
        public let data: T?
        public let error: String?
    }

    // v0.8.0: lazy EKEventStore for calendar/reminders access.
    //
    // Lazy so that the XCTest bundle (which has no Info.plist with
    // NSCalendarsUsageDescription) doesn't trigger a TCC crash at actor
    // init — only when a calendar tool is actually called. Reusing one
    // instance across calls means we pay the permission-dialog cost
    // ONCE (first call). EKEventStore is thread-safe per Apple docs.
    #if canImport(EventKit)
    private lazy var eventStore = EKEventStore()
    #endif

    // MARK: - iMessage

    public struct MessageSent: Codable, Sendable {
        public let to: String
        public let body: String
    }

    /// Send an iMessage to a buddy identified by phone number or email.
    /// Returns `ok:false` with the AppleScript stderr if Messages rejects
    /// the recipient (unknown contact, not iMessage-reachable, offline).
    func sendMessage(to: String, body: String) -> Result<MessageSent> {
        let escTo = to.replacingOccurrences(of: "\"", with: "\\\"")
        let escBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Uses `send ... to buddy` which targets iMessage by default. Service
        // is auto-resolved so the same script works for both phone and email.
        let script = """
        tell application "Messages"
            set targetService to 1st service whose service type = iMessage
            set targetBuddy to buddy "\(escTo)" of targetService
            send "\(escBody)" to targetBuddy
        end tell
        """
        let r = OsascriptRunner.run(script)
        guard r.ok else {
            return Result(ok: false, data: nil,
                          error: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Result(ok: true, data: MessageSent(to: to, body: body), error: nil)
    }

    public struct RecentThread: Codable, Sendable {
        public let participant: String
        public let lastMessagePreview: String?
    }

    /// List recent iMessage threads (participant names only — full message
    /// history requires Full Disk Access to `~/Library/Messages/chat.db`
    /// which we deliberately don't ask for). Returns up to `limit` threads.
    func listRecentMessageThreads(limit: Int) -> Result<[RecentThread]> {
        // AppleScript's Messages dictionary is narrow; we iterate `chats`
        // and grab participant handles. It won't give us unread counts or
        // timestamps without DB access, but it's enough to answer "who did
        // I last talk to" and provide a handle for follow-up sendMessage.
        let script = """
        tell application "Messages"
            set out to {}
            set n to \(max(1, min(limit, 50)))
            set c to chats
            repeat with i from 1 to (count of c)
                if i > n then exit repeat
                set thisChat to item i of c
                try
                    set p to (participants of thisChat)
                    set nameList to ""
                    repeat with px in p
                        set nameList to nameList & (handle of px) & ", "
                    end repeat
                    set end of out to nameList
                on error
                    set end of out to "(unknown)"
                end try
            end repeat
            return out
        end tell
        """
        let r = OsascriptRunner.run(script)
        guard r.ok else {
            return Result(ok: false, data: nil,
                          error: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // AppleScript returns a comma-separated list when the outer value is
        // a list. Each entry in our script ends with ", " — we split on
        // that outer boundary, then strip trailing commas.
        let text = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = text
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "(unknown)" }
        let threads = entries.map { RecentThread(participant: $0, lastMessagePreview: nil) }
        return Result(ok: true, data: threads, error: nil)
    }

    // MARK: - Mail

    public struct MailSent: Codable, Sendable {
        public let to: String
        public let subject: String
    }

    /// Compose + send an email via Mail.app. Supports TO, CC, BCC (comma-
    /// separated), subject, body, and optional send-now vs save-as-draft.
    /// Triggers the Mail automation permission prompt on first call.
    func sendMail(
        to: String,
        subject: String,
        body: String,
        cc: String?,
        bcc: String?,
        sendNow: Bool
    ) -> Result<MailSent> {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let ccBlock = (cc ?? "").split(separator: ",").map {
            "make new cc recipient at end of cc recipients with properties {address:\"\(esc(String($0).trimmingCharacters(in: .whitespaces)))\"}"
        }.joined(separator: "\n            ")
        let bccBlock = (bcc ?? "").split(separator: ",").map {
            "make new bcc recipient at end of bcc recipients with properties {address:\"\(esc(String($0).trimmingCharacters(in: .whitespaces)))\"}"
        }.joined(separator: "\n            ")
        let toBlock = to.split(separator: ",").map {
            "make new to recipient at end of to recipients with properties {address:\"\(esc(String($0).trimmingCharacters(in: .whitespaces)))\"}"
        }.joined(separator: "\n            ")

        let action = sendNow ? "send" : "activate"
        let script = """
        tell application "Mail"
            set newMsg to make new outgoing message with properties {subject:"\(esc(subject))", content:"\(esc(body))", visible:false}
            tell newMsg
            \(toBlock)
            \(ccBlock)
            \(bccBlock)
            end tell
            \(action)
        end tell
        """
        let r = OsascriptRunner.run(script)
        guard r.ok else {
            return Result(ok: false, data: nil,
                          error: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Result(ok: true, data: MailSent(to: to, subject: subject), error: nil)
    }

    // MARK: - Calendar

    public struct CalendarEvent: Codable, Sendable {
        public let summary: String
        public let startISO: String
        public let endISO: String
    }

    /// Create a Calendar event. `startISO` / `endISO` must be ISO-8601
    /// ("2026-04-21T15:00:00Z" or with local offset). `calendar` is the
    /// display name of the target calendar ("Work", "Home"); if nil we use
    /// the first visible calendar.
    func createCalendarEvent(
        summary: String,
        startISO: String,
        endISO: String,
        calendar: String?
    ) -> Result<CalendarEvent> {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        guard let start = parseISO(startISO), let end = parseISO(endISO) else {
            return Result(ok: false, data: nil,
                          error: "start/end must be ISO-8601 (e.g. 2026-04-21T15:00:00Z)")
        }
        // AppleScript date constructors want locale-specific strings; we
        // build a `date` via current date + seconds offset instead for
        // locale independence.
        let nowTimestamp = Date().timeIntervalSince1970
        let startOffset = Int(start.timeIntervalSince1970 - nowTimestamp)
        let endOffset = Int(end.timeIntervalSince1970 - nowTimestamp)
        let calSelector = calendar.map { "calendar \"\(esc($0))\"" } ?? "first calendar"
        let script = """
        tell application "Calendar"
            set startDate to (current date) + \(startOffset)
            set endDate to (current date) + \(endOffset)
            tell \(calSelector)
                make new event with properties {summary:"\(esc(summary))", start date:startDate, end date:endDate}
            end tell
        end tell
        """
        let r = OsascriptRunner.run(script)
        guard r.ok else {
            return Result(ok: false, data: nil,
                          error: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Result(
            ok: true,
            data: CalendarEvent(summary: summary, startISO: startISO, endISO: endISO),
            error: nil
        )
    }

    /// List upcoming events in the next `horizonDays` days across all
    /// calendars.
    ///
    /// v0.8.0: migrated from AppleScript (`every event of c whose ...`
    /// which took 15+ seconds for a 2-day horizon because it loops each
    /// event in every calendar with a whose-clause filter) to direct
    /// EventKit (EKEventStore.predicateForEvents + events(matching:)
    /// which is an indexed query against the calendar SQLite store and
    /// typically returns in <100ms for 30-day horizons).
    ///
    /// First call triggers the macOS Calendar TCC prompt. Subsequent
    /// calls return immediately if granted. If denied, returns a
    /// structured ok:false with an actionable hint.
    func listCalendarEvents(horizonDays: Int) async -> Result<[CalendarEvent]> {
        let days = max(1, min(horizonDays, 90))

        #if canImport(EventKit)
        // v0.8.1: structured status so writeOnly vs denied vs restricted
        // each get an actionable, distinct error. The previous single
        // "denied" message sent users on a wild goose chase when they
        // had actually granted write-only access in an earlier session.
        let access = await requestCalendarAccess()
        guard access.granted else {
            let message: String
            switch access.status {
            case "writeOnly":
                message = "Calendar access is write-only. listCalendarEvents needs FULL access to read events. In System Settings → Privacy & Security → Calendars, toggle mac-control-mcp to 'Full Access' (not 'Add Events Only'), then restart the MCP server."
            case "denied", "denied_after_prompt":
                message = "Calendar access denied. Grant in System Settings → Privacy & Security → Calendars (enable mac-control-mcp), then restart the MCP server."
            case "restricted":
                message = "Calendar access restricted by MDM / parental controls. An administrator must unblock Calendar access for this user account."
            default:
                message = "Calendar access not available (status=\(access.status)). Grant in System Settings → Privacy & Security → Calendars."
            }
            return Result(ok: false, data: nil, error: message)
        }

        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: days, to: start) else {
            return Result(ok: false, data: nil, error: "Failed to compute end date")
        }

        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil  // all granted calendars
        )
        let ekEvents = eventStore.events(matching: predicate)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let events = ekEvents.map { event in
            CalendarEvent(
                summary: event.title ?? "(no title)",
                startISO: iso.string(from: event.startDate),
                endISO: iso.string(from: event.endDate)
            )
        }
        return Result(ok: true, data: events, error: nil)
        #else
        return Result(ok: false, data: nil, error: "EventKit not available on this platform")
        #endif
    }

    #if canImport(EventKit)
    /// Request full-access to events via the macOS 14+ API.
    /// Returns (granted, statusString) so the caller can emit a precise
    /// error message rather than a bland "denied".
    ///
    /// v0.8.1: previously returned just Bool, which conflated
    /// `.denied` (user said no), `.restricted` (MDM blocked),
    /// `.writeOnly` (partial grant — can add events, cannot read) and
    /// the success of requesting the missing upgrade. `.writeOnly` in
    /// particular surfaces in practice when a prior app version asked
    /// only for write scope, and the upgrade-to-full request in a
    /// background MCP process never shows the UI. We now surface the
    /// exact state so listCalendarEvents can tell the user what to do.
    private func requestCalendarAccess() async -> (granted: Bool, status: String) {
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .fullAccess { return (true, "fullAccess") }
            if status == .denied { return (false, "denied") }
            if status == .restricted { return (false, "restricted") }
            if status == .writeOnly { return (false, "writeOnly") }

            // Slow path: show prompt / wait for user decision.
            let eventStoreRef = eventStore
            let granted: Bool = await withCheckedContinuation { continuation in
                eventStoreRef.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
            return (granted, granted ? "fullAccess" : "denied_after_prompt")
        } else {
            return (false, "macos_pre_14")
        }
    }
    #endif

    private func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: s)
    }

    // MARK: - Reminders

    public struct Reminder: Codable, Sendable {
        public let title: String
        public let dueISO: String?
        public let list: String?
    }

    /// Create a reminder in Reminders.app. Optional `due` and `list`.
    func createReminder(title: String, dueISO: String?, list: String?) -> Result<Reminder> {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let listSelector = list.map { "list \"\(esc($0))\"" } ?? "default list"
        var properties = "{name:\"\(esc(title))\""
        if let dueISO, let due = parseISO(dueISO) {
            let offset = Int(due.timeIntervalSince1970 - Date().timeIntervalSince1970)
            properties += ", due date:((current date) + \(offset))"
        }
        properties += "}"
        let script = """
        tell application "Reminders"
            tell \(listSelector)
                make new reminder with properties \(properties)
            end tell
        end tell
        """
        let r = OsascriptRunner.run(script)
        guard r.ok else {
            return Result(ok: false, data: nil,
                          error: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Result(ok: true, data: Reminder(title: title, dueISO: dueISO, list: list), error: nil)
    }

    public struct ReminderSummary: Codable, Sendable {
        public let title: String
        public let completed: Bool
        public let list: String
    }

    /// List reminders across all lists. Optional `includeCompleted` — default
    /// false so agents see only actionable items.
    func listReminders(includeCompleted: Bool, limit: Int) -> Result<[ReminderSummary]> {
        let cap = max(1, min(limit, 200))
        let filter = includeCompleted ? "" : "whose completed is false"
        let script = """
        tell application "Reminders"
            set out to {}
            set ls to lists
            repeat with l in ls
                try
                    set ln to (name of l as string)
                    set items to (every reminder of l \(filter))
                    set n to (count of items)
                    if n > \(cap) then set n to \(cap)
                    repeat with i from 1 to n
                        set r to item i of items
                        set t to (name of r as string)
                        set c to completed of r
                        set end of out to ln & "||" & t & "||" & (c as string)
                    end repeat
                end try
            end repeat
            return out
        end tell
        """
        let r = OsascriptRunner.run(script)
        guard r.ok else {
            return Result(ok: false, data: nil,
                          error: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let lines = r.stdout
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let reminders: [ReminderSummary] = lines.compactMap { line in
            let parts = line.components(separatedBy: "||")
            guard parts.count >= 3 else { return nil }
            return ReminderSummary(
                title: parts[1],
                completed: parts[2].lowercased() == "true",
                list: parts[0]
            )
        }
        return Result(ok: true, data: reminders, error: nil)
    }

    // MARK: - Contacts

    public struct Contact: Codable, Sendable {
        public let name: String
        public let phones: [String]
        public let emails: [String]
    }

    /// Search Contacts.app by name substring. Returns phone numbers + emails
    /// — useful for the "find Adel's phone" → "imessage_send" handoff.
    func searchContacts(query: String, limit: Int) -> Result<[Contact]> {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let cap = max(1, min(limit, 50))
        let script = """
        tell application "Contacts"
            set out to {}
            set matches to (every person whose name contains "\(esc(query))")
            set n to (count of matches)
            if n > \(cap) then set n to \(cap)
            repeat with i from 1 to n
                set p to item i of matches
                set nm to (name of p as string)
                set phoneList to ""
                repeat with ph in (phones of p)
                    set phoneList to phoneList & (value of ph as string) & ";"
                end repeat
                set emailList to ""
                repeat with em in (emails of p)
                    set emailList to emailList & (value of em as string) & ";"
                end repeat
                set end of out to nm & "||" & phoneList & "||" & emailList
            end repeat
            return out
        end tell
        """
        let r = OsascriptRunner.run(script)
        guard r.ok else {
            return Result(ok: false, data: nil,
                          error: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let lines = r.stdout
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // v0.7.1 fix (BUG 4): AppleScript's `phones of p` values can
        // contain embedded newlines (mobile numbers formatted by
        // Contacts.app) and stray left-parens when the phone field is
        // free-text. Strip whitespace + newlines, drop empties, clean
        // leading punctuation that isn't a `+` or digit.
        func cleanPhone(_ raw: String) -> String? {
            var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Strip a single leading `(` when it's immediately followed by
            // a `+` — seen in contacts stored as `(+31 (6) ...`.
            if s.hasPrefix("(+") { s.removeFirst() }
            return s.isEmpty ? nil : s
        }
        func cleanEmail(_ raw: String) -> String? {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, s.contains("@") else { return nil }
            return s
        }
        let contacts: [Contact] = lines.compactMap { line in
            let parts = line.components(separatedBy: "||")
            guard parts.count >= 3 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let phones = parts[1].split(separator: ";")
                .compactMap { cleanPhone(String($0)) }
            let emails = parts[2].split(separator: ";")
                .compactMap { cleanEmail(String($0)) }
            return Contact(name: name, phones: phones, emails: emails)
        }
        return Result(ok: true, data: contacts, error: nil)
    }
}
