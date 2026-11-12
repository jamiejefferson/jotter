import Foundation

/// Who is using Jotter and where their notes go. Kept in this Mac's preferences, so each
/// person's details stay on their own Mac and out of the code.
enum Profile {
    private static let d = UserDefaults.standard

    /// Full name, used in the notes prompt so actions are attributed to the right person.
    static var name: String {
        get { nonEmpty(d.string(forKey: "profileName")) ?? NSFullUserName() }
        set { d.set(newValue, forKey: "profileName") }
    }

    /// Other names people use for them in meetings, such as a nickname or initials.
    static var alsoKnownAs: String {
        get { nonEmpty(d.string(forKey: "profileAlsoKnownAs")) ?? firstName }
        set { d.set(newValue, forKey: "profileAlsoKnownAs") }
    }

    /// Anything the notes should know about the person: their role, how they like notes,
    /// where certain meetings belong.
    static var about: String {
        get { d.string(forKey: "profileAbout") ?? "" }
        set { d.set(newValue, forKey: "profileAbout") }
    }

    static var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }

    /// The short name shown on actions that are theirs.
    static var shortName: String {
        alsoKnownAs.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? firstName
    }

    /// The folder notes are filed in: `Projects/<project>/Meetings/` and `Meetings/Needs filing/`
    /// inside it. Defaults to an Obsidian vault called JacqVault where one exists (JJ's), else
    /// `~/Documents/Jotter`.
    static var notesFolder: URL {
        get {
            if let p = nonEmpty(d.string(forKey: "notesFolder")) { return URL(fileURLWithPath: p, isDirectory: true) }
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let vault = home.appendingPathComponent("Documents/_Obsidian Vaults/JacqVault", isDirectory: true)
            if FileManager.default.fileExists(atPath: vault.path) { return vault }
            return home.appendingPathComponent("Documents/Jotter", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "notesFolder") }
    }

    /// A Google Calendar id readable through the Composio command-line tool, for matching
    /// meetings to invites. Unset for most people, and then matching is skipped.
    static var calendarId: String? { nonEmpty(d.string(forKey: "calendarId")) }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
