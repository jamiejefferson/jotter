import AppKit
import SwiftUI

/// Today's calendar, read every ten minutes off the main thread, so the prompt and a
/// recording's project never wait on the calendar. Empty where no calendar is set up.
@MainActor
final class Agenda {
    static let shared = Agenda()
    private(set) var events: [WorkCalendar.Event] = []
    private var fetched: Date?
    private var fetching = false
    private var wait: TimeInterval = 600

    func refreshIfDue() {
        guard Profile.calendarId != nil, !fetching, fetched.map({ Date().timeIntervalSince($0) > wait }) ?? true else { return }
        fetching = true
        let now = Date()
        Task.detached(priority: .utility) {
            let list = WorkCalendar.fetch(from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(12 * 3600))
            await MainActor.run {
                // A failed read keeps the last list and tries again in a minute: the network is
                // often not back yet in the seconds after the lid opens.
                if let list { Agenda.shared.events = list }
                Agenda.shared.wait = list == nil ? 60 : 600
                Agenda.shared.fetched = Date()
                Agenda.shared.fetching = false
            }
        }
    }

    /// The meeting in progress, counting from ten minutes before its start.
    func current(at now: Date = Date()) -> WorkCalendar.Event? {
        events.filter { now >= $0.start.addingTimeInterval(-600) && now <= $0.end }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    /// A meeting about to start or just started: three minutes before to two minutes after.
    /// `last` is the previous check. When the Mac slept through that window, a meeting that
    /// began in the last half hour and is still running counts too. Only invites with other
    /// people or a call link count, so "lunch" and reminders in the calendar raise nothing.
    func starting(at now: Date = Date(), since last: Date? = nil) -> WorkCalendar.Event? {
        let slept = last.map { now.timeIntervalSince($0) > 60 } ?? false
        return events.filter { e in
            guard now >= e.start.addingTimeInterval(-180), Self.isMeeting(e) else { return false }
            if now <= e.start.addingTimeInterval(120) { return true }
            guard slept, let last else { return false }
            return last <= e.start.addingTimeInterval(120) && now <= e.start.addingTimeInterval(1800) && now < e.end
        }.max { $0.start < $1.start }
    }

    static func isMeeting(_ e: WorkCalendar.Event) -> Bool {
        let d = e.description.lowercased()
        return !e.invitees.isEmpty || ["teams.microsoft.com", "teams.live.com", "zoom.us", "meet.google.com", "webex.com"].contains { d.contains($0) }
    }
}

/// The card that offers to record a meeting. It names the project matched from the invite,
/// says what earlier notes left open, and can wait and start by itself at the invite time.
@MainActor
final class PromptCard: ObservableObject {
    static let shared = PromptCard()
    enum Stage { case hidden, asking, waiting }

    @Published private(set) var stage: Stage = .hidden
    @Published private(set) var event: WorkCalendar.Event?
    /// The app holding the microphone, when that is what raised the card.
    @Published private(set) var app: String?
    @Published private(set) var matched = false
    @Published private(set) var projects: [String] = []
    @Published private(set) var summary = ""
    @Published var project = "" { didSet { if project != oldValue { matched = false; summarise() } } }

    private var panel: NSPanel?
    private var startTimer: Timer?
    private var expiry: Timer?
    var preview = false

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// True when "Start at" can be offered: the invite time is still ahead.
    var canWait: Bool { event.map { $0.start.timeIntervalSinceNow > 20 } ?? false }

    func ask(event: WorkCalendar.Event?, app: String?) {
        self.event = event
        self.app = app
        projects = Projects.list()
        let match = event.flatMap { ProjectMatch.project(forInvite: $0.title, projects: projects) }
        project = match ?? ""
        matched = match != nil
        summarise()
        stage = .asking
        show()
        expiry?.invalidate()
        // An untouched card for a calendar meeting goes ten minutes after the start.
        if app == nil, let event {
            expiry = Timer.scheduledTimer(withTimeInterval: max(60, event.start.timeIntervalSinceNow + 600), repeats: false) { _ in
                Task { @MainActor in if PromptCard.shared.stage == .asking { PromptCard.shared.close() } }
            }
        }
    }

    private func summarise() {
        guard !project.isEmpty else { summary = ""; return }
        let b = Brief.load(project: project)
        guard let last = b.lastMet else { summary = "No earlier notes for this project."; return }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM"
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        if b.questions.isEmpty && b.actions.isEmpty { summary = "Last met \(f.string(from: last)). Nothing left open."; return }
        summary = "Since \(f.string(from: last)): \(count(b.questions.count, "open question", "open questions")), "
            + "\(count(b.actions.count, "action to chase", "actions to chase"))."
    }

    func recordNow() {
        let project = self.project
        hide()
        let r = JotterApp.recorder
        if !r.isRecording {
            r.start(.meeting, project: project)
            CallWatcher.shared.recordingStartedFromPrompt()
        }
    }

    /// Shrinks to a small bar and records by itself at the invite time.
    func startAtInvite() {
        guard let event, canWait else { return recordNow() }
        expiry?.invalidate()
        stage = .waiting
        show()
        startTimer?.invalidate()
        startTimer = Timer.scheduledTimer(withTimeInterval: event.start.timeIntervalSinceNow, repeats: false) { _ in
            Task { @MainActor in if PromptCard.shared.stage == .waiting { PromptCard.shared.recordNow() } }
        }
    }

    func close() { hide() }

    /// The call that raised the card has ended, so the question no longer applies.
    func withdrawMicPrompt() {
        if stage == .asking, app != nil { hide() }
    }

    private func hide() {
        startTimer?.invalidate(); startTimer = nil
        expiry?.invalidate(); expiry = nil
        stage = .hidden
        panel?.orderOut(nil)
    }

    /// The project for a recording started by hand: the one on the card if it is for this
    /// meeting, otherwise the match for the invite in progress. The card then steps aside.
    func claimProject(at now: Date = Date()) -> (project: String, event: WorkCalendar.Event?) {
        if stage != .hidden {
            let p = project, e = event
            hide()
            if !p.isEmpty { return (p, e) }
        }
        let e = Agenda.shared.current(at: now)
        return (e.flatMap { ProjectMatch.project(forInvite: $0.title) } ?? "", e)
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let host = NSHostingController(rootView: AnyView(PromptView().environmentObject(self)))
            host.sizingOptions = [.preferredContentSize]
            p.contentViewController = host
            p.appearance = Theme.appearance
            panel = p
        }
        guard let panel else { return }
        let wasVisible = panel.isVisible
        // Let the view take its new shape, then keep the top edge where it was.
        DispatchQueue.main.async {
            let size = panel.contentView?.fittingSize ?? panel.frame.size
            if wasVisible {
                panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height), display: true)
            } else if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 12, width: size.width, height: size.height), display: true)
            }
            panel.orderFrontRegardless()
        }
    }
}

/// Six dots that say the surface can be dragged.
struct DragGrip: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(Theme.outline)
        .frame(width: 10, height: 16)
        .help("Drag to move")
    }
}

/// A project menu bound to any choice. `empty` is what it reads before a project is picked.
struct ProjectPicker: View {
    @Binding var selection: String
    let projects: [String]
    var empty = "Project…"
    var urge = false
    var size: CGFloat = 12
    var chevron = false

    var body: some View {
        Menu {
            Button("Decide later") { selection = "" }
            Divider()
            ForEach(projects.prefix(12), id: \.self) { p in Button(p) { selection = p } }
            if projects.count > 12 {
                Menu("All projects") {
                    ForEach(projects.sorted(), id: \.self) { p in Button(p) { selection = p } }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.isEmpty ? empty : selection).font(Theme.font(size, selection.isEmpty ? .regular : .medium)).lineLimit(1)
                if chevron { Image(systemName: "chevron.down").font(.system(size: size - 4, weight: .semibold)) }
            }
            .foregroundStyle(selection.isEmpty ? (urge ? Theme.accentText : Theme.muted) : Theme.ink)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct PromptView: View {
    @EnvironmentObject var c: PromptCard

    var body: some View {
        Group {
            if c.stage == .waiting { waiting } else { card }
        }
        .environment(\.colorScheme, .dark)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DragGrip()
                Dot()
                Text("Jot notes for this meeting?").font(Theme.font(15, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button { c.close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted) }
                    .buttonStyle(.plain).help("Close")
            }
            Text(context).font(Theme.font(12)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            HStack {
                ProjectPicker(selection: $c.project, projects: c.projects, empty: "Choose project", size: 14)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Theme.subtleFill))
            .overlay(Capsule().strokeBorder(Theme.subtleLine))
            .padding(.top, 8)
            if !c.summary.isEmpty {
                Text(c.summary).font(Theme.font(13, .light)).foregroundStyle(Theme.body)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }
            HStack(spacing: 8) {
                Button("Record now") { c.recordNow() }.buttonStyle(PillButtonStyle(primary: true))
                if c.canWait, let e = c.event {
                    Button("Start at \(PromptCard.time(e.start))") { c.startAtInvite() }.buttonStyle(PillButtonStyle())
                }
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(width: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.ground))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.subtleLine, lineWidth: 1))
    }

    /// One line saying why the card is here and how sure the project is.
    private var context: String {
        if let e = c.event {
            let what = "\u{201C}\(e.title)\u{201D} at \(PromptCard.time(e.start))"
            return c.matched ? "Project, matched from \(what)" : "Project for \(what)"
        }
        if let app = c.app { return "\(app) is using your microphone." }
        return "Project"
    }

    private var waiting: some View {
        HStack(spacing: 12) {
            DragGrip()
            Circle().strokeBorder(Theme.muted, lineWidth: 1.5).frame(width: 8, height: 8)
            Text("starts \(c.event.map { PromptCard.time($0.start) } ?? "")").font(Theme.font(13, .semibold)).foregroundStyle(Theme.ink)
            Rectangle().fill(Theme.rule).frame(width: 1, height: 16)
            ProjectPicker(selection: $c.project, projects: c.projects, empty: "Choose project", urge: true)
            Button("Record now") { c.recordNow() }.buttonStyle(PillButtonStyle(primary: true, small: true))
            Button { c.close() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(RecordingHUD.IconPill()).help("Don't record this meeting")
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 7)
        .background(Capsule().fill(Theme.ground))
        .overlay(Capsule().strokeBorder(Theme.subtleLine, lineWidth: 1))
        .fixedSize()
    }
}
