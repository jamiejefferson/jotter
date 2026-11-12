import Foundation

/// Finds the calendar invite for a meeting, so notes get the real meeting title and full
/// names. Works where an Outlook calendar is imported into Google Calendar and the Composio
/// command-line tool is set up; the calendar id is a per-person setting (`Profile.calendarId`).
enum WorkCalendar {
    static let composio = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".composio/composio")

    struct Event {
        let title: String
        let start: Date
        let end: Date
        let invitees: [String]
        let description: String
    }

    /// The invite that best overlaps a meeting starting at `start`, or nil.
    static func invite(for start: Date) -> Event? {
        let events = list(from: start.addingTimeInterval(-3 * 3600), to: start.addingTimeInterval(3 * 3600))
        let t = start.timeIntervalSince1970
        var best: Event?, bestScore = Double.infinity
        for e in events {
            let s = e.start.timeIntervalSince1970, en = e.end.timeIntervalSince1970
            let inside = t >= s - 600 && t <= en
            let score = inside ? abs(t - s) : abs(t - s) + 3600
            if score < bestScore && abs(t - s) <= 1800 + (inside ? en - s : 0) { best = e; bestScore = score }
        }
        return best
    }

    static func list(from: Date, to: Date) -> [Event] {
        guard let calendarId = Profile.calendarId, FileManager.default.isExecutableFile(atPath: composio.path) else { return [] }
        let iso = ISO8601DateFormatter()
        let args: [String: Any] = ["calendarId": calendarId, "timeMin": iso.string(from: from), "timeMax": iso.string(from: to),
                                   "singleEvents": true, "maxResults": 50]
        guard let argData = try? JSONSerialization.data(withJSONObject: args), let argText = String(data: argData, encoding: .utf8) else { return [] }
        let p = Process()
        p.executableURL = composio
        p.arguments = ["execute", "GOOGLECALENDAR_EVENTS_LIST", "-d", argText]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return [] }
        // Composio can hang on a dropped connection; give up after 30 seconds.
        let deadline = Date().addingTimeInterval(30)
        var out = Data()
        while p.isRunning && Date() < deadline {
            out.append(pipe.fileHandleForReading.availableData)
        }
        if p.isRunning { p.terminate(); return [] }
        out.append(pipe.fileHandleForReading.readDataToEndOfFile())
        guard let text = String(data: out, encoding: .utf8), let brace = text.firstIndex(of: "{"),
              var json = try? JSONSerialization.jsonObject(with: Data(text[brace...].utf8)) as? [String: Any] else { return [] }
        if json["storedInFile"] as? Bool == true, let path = json["outputFilePath"] as? String,
           let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            json = j
        }
        let items = ((json["data"] as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        return items.compactMap { e in
            guard let s = (e["start"] as? [String: Any])?["dateTime"] as? String, let start = iso.date(from: s),
                  e["status"] as? String != "cancelled" else { return nil }
            let title = (e["summary"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if title.lowercased().hasPrefix("declined:") { return nil }
            let end = ((e["end"] as? [String: Any])?["dateTime"] as? String).flatMap(iso.date) ?? start
            let description = e["description"] as? String ?? ""
            var names = invitees(description)
            for a in (e["attendees"] as? [[String: Any]]) ?? [] where a["self"] as? Bool != true && a["resource"] as? Bool != true {
                if let n = a["displayName"] as? String, !n.isEmpty { names.append(n) }
                else if let em = a["email"] as? String { names.append(nameFromEmail(em)) }
            }
            var seen = Set<String>()
            return Event(title: title, start: start, end: end, invitees: names.filter { seen.insert($0).inserted }, description: description)
        }
    }

    private static func nameFromEmail(_ email: String) -> String {
        email.split(separator: "@").first.map { $0.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ").capitalized } ?? email
    }

    /// Outlook invites imported into Google carry their attendees in the description.
    private static func invitees(_ description: String) -> [String] {
        var names: [String] = []
        let text = description.replacingOccurrences(of: "\r", with: "")
        for line in text.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard let label = ["From:", "To:", "Cc:", "Required Attendees:", "Optional Attendees:", "Organizer:"].first(where: { l.lowercased().hasPrefix($0.lowercased()) })
            else { continue }
            for part in l.dropFirst(label.count).split(whereSeparator: { $0 == ";" || $0 == "," }) {
                let p = part.trimmingCharacters(in: .whitespaces)
                let email = p.range(of: "[\\w.+-]+@[\\w.-]+\\.[a-zA-Z]{2,}", options: .regularExpression).map { String(p[$0]) }
                var name = p.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                if let email, name.isEmpty || name.contains("@") { name = nameFromEmail(email) }
                if !name.isEmpty && name.count <= 60 && !name.lowercased().hasPrefix("mailto") { names.append(name) }
            }
        }
        return names
    }
}
