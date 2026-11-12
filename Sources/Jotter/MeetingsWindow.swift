import AppKit
import SwiftUI

/// The review window: every meeting Jotter recorded, with its notes and transcript, and a
/// project menu that moves the filed note (and its transcript) to another project.
@MainActor
final class MeetingsModel: ObservableObject {
    struct Item: Identifiable, Hashable {
        let id: URL            // the recording folder
        let title: String
        let started: Date
        let seconds: Double
        let project: String    // where the note is filed, or "" if not yet
        let note: URL?
        let hasTranscript: Bool
        let hasNotes: Bool
    }

    @Published private(set) var items: [Item] = []
    @Published var selection: URL?
    @Published var showTranscript = false
    @Published private(set) var busy: String?
    @Published private(set) var problem: String?
    @Published private(set) var projects: [String] = []

    init() {
        reload()
        NotificationCenter.default.addObserver(forName: .jotterMeetingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.reload()
                // "View" on the recording bar asks for one meeting.
                if let want = MeetingsWindow.shared.pendingSelection, self?.items.contains(where: { $0.id == want }) == true {
                    self?.select(want)
                    self?.showTranscript = false
                    MeetingsWindow.shared.pendingSelection = nil
                }
            }
        }
    }

    func reload() {
        projects = Projects.list()
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: Store.recordings, includingPropertiesForKeys: nil)) ?? []
        items = folders.filter { $0.lastPathComponent.contains("-meeting") }.compactMap { f in
            let info = MeetingNotes.readInfo(f)
            let notes = (try? JSONSerialization.jsonObject(with: Data(contentsOf: f.appendingPathComponent("notes.json")))) as? [String: Any]
            let started = (info["startedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date.distantPast
            let note = (info["note"] as? String).map { URL(fileURLWithPath: $0) }.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
            var project = ""
            if let note {
                project = note.path.hasPrefix(MeetingNotes.folder(for: MeetingNotes.needsFiling).path)
                    ? MeetingNotes.needsFiling : note.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            }
            let label = info["label"] as? String ?? ""
            return Item(id: f, title: (notes?["title"] as? String) ?? (label.isEmpty ? "Meeting" : label), started: started,
                        seconds: info["seconds"] as? Double ?? 0, project: project, note: note,
                        hasTranscript: fm.fileExists(atPath: f.appendingPathComponent("transcript.md").path),
                        hasNotes: notes != nil)
        }.sorted { $0.started > $1.started }
        if selection == nil || !items.contains(where: { $0.id == selection }), let first = items.first?.id { select(first) }
    }

    var selected: Item? { items.first { $0.id == selection } }

    func select(_ id: URL) {
        selection = id
    }

    /// A standard folder chooser opened at the vault's Projects folder. Pick a project, or
    /// make one with New Folder; a new folder gets its index and `Meetings/` folder.
    func chooseProject(for item: Item, in window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        try? FileManager.default.createDirectory(at: Projects.folder, withIntermediateDirectories: true)
        panel.directoryURL = Projects.folder
        panel.prompt = "File here"
        let suggested = notes(item)["suggestedNewProject"] as? String ?? ""
        panel.message = "Choose the project folder for this meeting, or make one with New Folder."
            + (suggested.isEmpty ? "" : " Suggested: \(suggested)")
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.file(item, inFolder: url)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    func file(_ item: Item, inFolder url: URL) {
        let chosen = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let projects = Projects.folder.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let needs = MeetingNotes.folder(for: MeetingNotes.needsFiling).standardizedFileURL.resolvingSymlinksInPath().pathComponents
        if chosen.starts(with: needs) { move(item, to: MeetingNotes.needsFiling); return }
        // Anything inside a project folder counts as that project.
        guard chosen.count > projects.count, chosen.starts(with: projects) else {
            problem = "Choose a folder inside Projects in the vault."
            return
        }
        let about = (notes(item)["subject"] as? String).map { "Meetings about \($0)." } ?? ""
        guard let name = MeetingNotes.createProject(chosen[projects.count], about: about) else {
            problem = "Couldn't use that folder as a project."
            return
        }
        move(item, to: name)
    }

    func notes(_ item: Item) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: item.id.appendingPathComponent("notes.json")))) as? [String: Any] ?? [:]
    }

    func transcript(_ item: Item) -> [String] {
        let md = (try? String(contentsOf: item.id.appendingPathComponent("transcript.md"), encoding: .utf8)) ?? ""
        var lines = md.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        return lines.filter { !$0.isEmpty && !$0.hasPrefix("# ") }
    }

    func move(_ item: Item, to project: String) {
        guard project != item.project else { return }
        do {
            _ = try MeetingNotes.move(recording: item.id, to: project)
            problem = nil
        } catch { problem = error.localizedDescription }
        reload()
    }

    /// Writes the notes again, for a meeting whose notes failed or that predates notes.
    func writeNotes(_ item: Item) {
        busy = "Writing notes with Kimi K3…"
        problem = nil
        Task {
            do { _ = try await MeetingNotes.generate(folder: item.id) } catch { problem = error.localizedDescription }
            busy = nil
            reload()
        }
    }

    func transcribe(_ item: Item) {
        guard #available(macOS 26.0, *) else { return }
        busy = "Transcribing on this Mac…"
        Task {
            do { try await Transcribe.transcribe(folder: item.id, wanted: "en-GB") } catch { problem = error.localizedDescription }
            busy = nil
            reload()
        }
    }
}

struct MeetingsView: View {
    @StateObject private var m = MeetingsModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Wordmark(size: 26)
                Spacer()
                KeyHints()
                Spacer()
                Button("Recordings folder") { NSWorkspace.shared.open(Store.recordings) }.buttonStyle(PillButtonStyle(small: true))
            }
            .padding(.horizontal, 32).frame(height: 68)
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(spacing: 0) {
                list.frame(width: 320)
                Rectangle().fill(Theme.rule).frame(width: 1)
                Group {
                    if let item = m.selected { Detail(item: item).environmentObject(m) } else {
                        Text("No meetings yet. Double-tap \(HoldKey.current.symbol) to record one.").font(Theme.text).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(Theme.text)
        .foregroundStyle(Theme.ink)
        .background(Theme.ground)
        .frame(minWidth: 1000, minHeight: 600)
        .environment(\.colorScheme, .dark)
        .onAppear { m.reload() }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(m.items) { item in
                    let on = item.id == m.selection
                    Button { m.select(item.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(Theme.font(14, on ? .semibold : .medium)).foregroundStyle(Theme.ink)
                                .lineLimit(2).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                            Text("\(Self.when(item.started)) · \(Recorder.clock(item.seconds))").font(Theme.meta).foregroundStyle(Theme.muted)
                            HStack(spacing: 6) {
                                if item.project == MeetingNotes.needsFiling || item.project.isEmpty { Dot() }
                                Text(item.project.isEmpty ? (item.hasNotes ? "Not filed" : "No notes yet") : item.project)
                                    .font(Theme.meta).foregroundStyle(item.project == MeetingNotes.needsFiling || item.project.isEmpty ? Theme.redText : Theme.body)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32).padding(.vertical, 16)
                        .background(on ? Theme.zone : Theme.rail)
                        .overlay(alignment: .leading) { if on { Rectangle().fill(Theme.accent).frame(width: 3) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(Theme.rule).frame(height: 1)
                }
            }
        }
        .background(Theme.rail)
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: d)
    }

    struct Detail: View {
        let item: MeetingsModel.Item
        @EnvironmentObject var m: MeetingsModel

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    filing
                    HStack(spacing: 24) {
                        tab("Notes", on: !m.showTranscript) { m.showTranscript = false }
                        tab("Transcript", on: m.showTranscript) { m.showTranscript = true }
                        Spacer()
                    }
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                    if let b = m.busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(b).font(Theme.secondary).foregroundStyle(Theme.body) } }
                    if let p = m.problem { Text(p).font(Theme.secondary).foregroundStyle(Theme.redText) }
                    VStack(alignment: .leading, spacing: 14) {
                        if m.showTranscript { transcript } else { notes }
                    }
                    .textSelection(.enabled)
                }
                .padding(.horizontal, 48).padding(.vertical, 36)
                .frame(maxWidth: 800, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A new meeting or tab starts at the top.
            .id("\(item.id.path)-\(m.showTranscript)")
        }

        private var header: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(Theme.h1).tracking(-1.4).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Text("\(MeetingsView.when(item.started)) · \(Recorder.clock(item.seconds))").font(Theme.secondary).foregroundStyle(Theme.muted)
                    if let invite = invite { StatusPill(text: invite, style: .outline).lineLimit(1).truncationMode(.tail) }
                }
            }
        }

        private var invite: String? {
            (MeetingNotes.readInfo(item.id)["invite"] as? [String: Any])?["title"] as? String
        }

        private var filing: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Filed in").font(Theme.secondary).foregroundStyle(Theme.muted).fixedSize()
                    Button {
                        m.chooseProject(for: item, in: MeetingsWindow.shared.window)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 12, weight: .semibold))
                            Text(item.project.isEmpty ? "Choose a project" : item.project)
                        }
                    }
                    .buttonStyle(PillButtonStyle()).fixedSize()
                    .disabled(!item.hasNotes)
                    .help("Choose or create the project folder")
                    Spacer()
                    if let note = item.note {
                        Button("Open Folder") { NSWorkspace.shared.activateFileViewerSelecting([note]) }
                            .buttonStyle(PillButtonStyle(small: true)).fixedSize()
                    }
                    Button("Show recording") { NSWorkspace.shared.activateFileViewerSelecting([item.id]) }.buttonStyle(PillButtonStyle(small: true)).fixedSize()
                }
                if item.project == MeetingNotes.needsFiling, let suggested {
                    Text("Suggested project: \(suggested)").font(Theme.meta).foregroundStyle(Theme.muted)
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.zone))
        }

        private func tab(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Text(title).font(Theme.font(14, on ? .semibold : .regular)).foregroundStyle(on ? Theme.ink : Theme.body)
                    .padding(.bottom, 10)
                    .overlay(alignment: .bottom) { Rectangle().fill(on ? Theme.ink : Color.clear).frame(height: 2) }
            }
            .buttonStyle(.plain)
        }

        private var suggested: String? {
            let s = m.notes(item)["suggestedNewProject"] as? String ?? ""
            return s.isEmpty ? nil : s
        }

        @ViewBuilder private var notes: some View {
            let n = m.notes(item)
            if n.isEmpty {
                Text(item.hasTranscript ? "No notes yet." : "No transcript yet.").foregroundStyle(Theme.muted)
                if item.hasTranscript {
                    Button("Write notes") { m.writeNotes(item) }.buttonStyle(PillButtonStyle(primary: true)).disabled(m.busy != nil)
                } else {
                    Button("Transcribe") { m.transcribe(item) }.buttonStyle(PillButtonStyle(primary: true)).disabled(m.busy != nil)
                }
            } else {
                if let gist = n["gist"] as? String, !gist.isEmpty {
                    Text(gist).font(Theme.font(19, .medium)).tracking(-0.8).fixedSize(horizontal: false, vertical: true)
                }
                if let summary = n["summary"] as? String, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(summary.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated()), id: \.offset) { _, l in
                            let t = l.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("–").foregroundStyle(Theme.muted)
                                Text((try? AttributedString(markdown: t)) ?? AttributedString(t)).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                section("Decisions", (n["decisions"] as? [String]) ?? [])
                let goals = (n["goals"] as? [[String: Any]]) ?? []
                let actions = (n["actions"] as? [[String: Any]]) ?? []
                if !actions.isEmpty {
                    Text("Goals and actions").font(Theme.h2).tracking(-0.7).padding(.top, 8)
                    ForEach(Array(goals.enumerated()), id: \.offset) { _, g in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(g["title"] as? String ?? "").font(Theme.font(15, .semibold))
                                if g["stated"] as? Bool == false { StatusPill(text: "inferred", style: .dashed) }
                            }
                            .padding(.bottom, 10)
                            ForEach(Array(actions.filter { $0["goalKey"] as? String == g["key"] as? String }.enumerated()), id: \.offset) { _, a in
                                action(a)
                            }
                        }
                        .card(padding: 18)
                    }
                }
                section("Open questions", (n["openQuestions"] as? [String]) ?? [])
                Button("Write notes again") { m.writeNotes(item) }.buttonStyle(PillButtonStyle(small: true)).disabled(m.busy != nil).padding(.top, 8)
            }
        }

        private func action(_ a: [String: Any]) -> some View {
            let mine = a["attribution"] as? String == "me"
            let who: String
            switch a["attribution"] as? String {
            case "me": who = "You"
            case "other": who = a["owner"] as? String ?? ""
            default: who = "To be attributed"
            }
            return VStack(alignment: .leading, spacing: 4) {
                Text(a["headline"] as? String ?? "").font(Theme.font(14, .semibold))
                Text(a["text"] as? String ?? "").font(Theme.secondary).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    StatusPill(text: who, style: mine ? .accent : who == "To be attributed" ? .dashed : .outline)
                    if let due = a["due"] as? String, !due.isEmpty { StatusPill(text: "due \(due)", style: .solid) }
                    if a["stated"] as? Bool == false { StatusPill(text: "suggested", style: .dashed) }
                }
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
        }

        @ViewBuilder private func section(_ title: String, _ items: [String]) -> some View {
            if !items.isEmpty {
                Text(title).font(Theme.h2).tracking(-0.7).padding(.top, 8)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("–").foregroundStyle(Theme.muted)
                            Text(i).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }

        @ViewBuilder private var transcript: some View {
            let lines = m.transcript(item)
            if lines.isEmpty { Text("No transcript yet.").foregroundStyle(Theme.muted) }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    Text((try? AttributedString(markdown: l)) ?? AttributedString(l)).font(Theme.secondary).foregroundStyle(Theme.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Owns the Meetings window, so it can be opened from the menu, after a meeting, or from
/// the command line (`Jotter --show-meetings` while Jotter runs).
@MainActor
final class MeetingsWindow {
    static let shared = MeetingsWindow()
    static let showRequest = Notification.Name("com.eqtr.jotter.showMeetings")
    private(set) var window: NSWindow?
    /// A meeting to select when the window next reloads.
    var pendingSelection: URL?

    func show(meeting: URL) {
        pendingSelection = meeting
        show()
    }

    private init() {
        DistributedNotificationCenter.default().addObserver(forName: Self.showRequest, object: nil, queue: .main) { _ in
            Task { @MainActor in MeetingsWindow.shared.show() }
        }
    }

    /// Call once at launch so outside requests are heard.
    static func listen() { _ = shared }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "Jotter"
            w.titleVisibility = .hidden
            w.appearance = Theme.appearance
            w.backgroundColor = Theme.groundNS
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: MeetingsView())
            w.contentMinSize = NSSize(width: 1000, height: 600)
            w.setFrameAutosaveName("JotterMeetings")
            if !w.setFrameUsingName("JotterMeetings") { w.center() }
            // A frame saved before the minimum grew would cut the content off at both sides.
            if w.frame.width < 1000 || w.frame.height < 600 {
                w.setContentSize(NSSize(width: max(w.frame.width, 1000), height: max(w.contentLayoutRect.height, 600)))
            }
            window = w
        }
        NotificationCenter.default.post(name: .jotterMeetingsChanged, object: nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// `Jotter --file-check <recording> <folder>` files a meeting as if that folder were chosen.
@MainActor
enum FileCheck {
    static func run(recording: URL, folder: URL) {
        let m = MeetingsModel()
        m.reload()
        guard let item = m.items.first(where: { $0.id.standardizedFileURL == recording.standardizedFileURL }) else { print("no such meeting"); return }
        m.file(item, inFolder: folder)
        m.reload()
        print(m.problem ?? "filed in: \(m.items.first { $0.id == item.id }?.project ?? "?")")
    }
}
