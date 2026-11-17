import AppKit
import Combine
import SwiftUI

/// Vault projects to file a recording under, most recently touched first.
enum Projects {
    static var folder: URL { Profile.notesFolder.appendingPathComponent("Projects", isDirectory: true) }

    static func list() -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let dirs = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        func touched(_ u: URL) -> Date {
            let index = u.appendingPathComponent("_index.md")
            return ((try? fm.attributesOfItem(atPath: index.path))?[.modificationDate] as? Date) ?? .distantPast
        }
        return dirs.sorted { touched($0) > touched($1) }.map { $0.lastPathComponent }
    }
}

/// A small floating bar while a recording runs, so it is always clear that Jotter is
/// recording. It shows the time, the project, and buttons to pause and stop. It never
/// takes focus from the call, and it can be dragged anywhere; it remembers where.
/// With a project chosen it carries the number of items earlier notes left open, and
/// opens out into the call brief.
@MainActor
final class RecordingHUD: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let recorder: Recorder
    private var watching: [Any] = []

    init(recorder: Recorder) { self.recorder = recorder }

    func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .floating
            p.hasShadow = true
            p.isMovableByWindowBackground = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            // The panel follows the bar's size as it changes from recording to the notes result.
            let host = NSHostingController(rootView: AnyView(Bar().environmentObject(recorder).environmentObject(recorder.brief)))
            host.sizingOptions = [.preferredContentSize]
            p.contentViewController = host
            p.appearance = Theme.appearance
            if !p.setFrameUsingName("JotterRecordingBar"), let screen = NSScreen.main {
                let size = p.contentView?.fittingSize ?? NSSize(width: 360, height: 44)
                let f = screen.visibleFrame
                p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 12, width: size.width, height: size.height), display: true)
            }
            p.setFrameAutosaveName("JotterRecordingBar")
            p.delegate = self
            panel = p
            let brief = recorder.brief
            watching = [
                brief.$open.sink { [weak self] open in self?.share(open: open, visible: brief.visibleWhenSharing) },
                brief.$visibleWhenSharing.sink { [weak self] visible in self?.share(open: brief.open, visible: visible) },
            ]
        }
        // The saved frame may be the open brief's. Keep its top-left corner and take the bar's size.
        if let panel, let size = panel.contentView?.fittingSize {
            panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    /// The open brief is left out of screen shares and screenshots unless the switch says otherwise.
    private func share(open: Bool, visible: Bool) {
        panel?.sharingType = open && !visible ? .none : .readOnly
    }

    /// The brief opens downwards from the bar. If that runs off the screen, move it back on.
    func windowDidResize(_ notification: Notification) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = panel.frame
        if f.minY < v.minY { f.origin.y = v.minY }
        if f.maxY > v.maxY { f.origin.y = v.maxY - f.height }
        if f.maxX > v.maxX { f.origin.x = v.maxX - f.width }
        if f.minX < v.minX { f.origin.x = v.minX }
        if f != panel.frame { panel.setFrame(f, display: true) }
    }

    struct Bar: View {
        @EnvironmentObject var r: Recorder
        @EnvironmentObject var b: BriefModel

        var body: some View {
            if r.kind == nil && r.showingResult { result }
            else if b.open && r.kind == .meeting { BriefPanel() }
            else { recording }
        }

        /// After a meeting stops: progress, then where the notes went with a way to open them.
        private var result: some View {
            HStack(spacing: 12) {
                if r.saving || r.transcribing || r.writingNotes {
                    ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 16, height: 16)
                    Text(r.saving ? "Saving…" : r.transcribing ? "Transcribing…" : "Writing notes…")
                        .font(Theme.font(13, .semibold)).foregroundStyle(Theme.ink)
                } else if let last = r.last, last.note != nil {
                    Dot(color: Theme.accent)
                    Text("Notes ready").font(Theme.font(13, .semibold)).foregroundStyle(Theme.ink)
                    Text(Self.filed(last.note!)).font(Theme.font(13)).foregroundStyle(Theme.muted).lineLimit(1)
                    Button("View") { r.viewResult() }.buttonStyle(PillButtonStyle(primary: true, small: true))
                } else {
                    Text(r.last?.warning ?? "Saved, with no notes.").font(Theme.font(13)).foregroundStyle(Theme.body)
                        .lineLimit(1).frame(maxWidth: 320, alignment: .leading)
                    Button("View") { r.viewResult() }.buttonStyle(PillButtonStyle(small: true))
                }
                Button { r.dismissResult() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(IconPill())
                    .help("Close")
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 7)
            .background(Capsule().fill(Theme.ground))
            .overlay(Capsule().strokeBorder(Theme.subtleLine, lineWidth: 1))
            .fixedSize()
            .environment(\.colorScheme, .dark)
        }

        static func filed(_ note: URL) -> String {
            let project = note.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            return note.path.contains("/Meetings/Needs filing/") ? "in Needs filing" : "in \(project)"
        }

        private var recording: some View {
            HStack(spacing: 12) {
                DragGrip()
                RecordingState()
                Rectangle().fill(Theme.rule).frame(width: 1, height: 16)
                ProjectMenu(empty: r.kind == .meeting ? "Choose project" : "Project…", urge: r.kind == .meeting)
                if r.kind == .meeting && b.left > 0 {
                    Button { b.open = true } label: {
                        Text("\(b.left)").font(Theme.font(12, .semibold)).monospacedDigit().foregroundStyle(Theme.inverse)
                            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
                            .background(Capsule().fill(Theme.ink))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(b.left) still to cover from earlier notes. Click to open the brief.")
                } else if r.kind == .meeting && !b.project.isEmpty && b.hasNotes {
                    Button { b.open = true } label: { Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(IconPill()).help("Open the brief")
                }
                Controls()
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 7)
            .background(Capsule().fill(Theme.ground))
            .overlay(Capsule().strokeBorder(Theme.subtleLine, lineWidth: 1))
            .fixedSize()
            .environment(\.colorScheme, .dark)
        }
    }

    /// The blinking dot, the word and the clock.
    struct RecordingState: View {
        @EnvironmentObject var r: Recorder
        var body: some View {
            HStack(spacing: 10) {
                Dot(color: r.paused ? Theme.muted : Theme.dot)
                    // Blinks about once a second while recording, driven by the recording clock.
                    .opacity(r.paused || Int(r.elapsed * 1.25) % 2 == 0 ? 1 : 0.3)
                Text(r.paused ? "paused" : (r.kind == .note ? "note" : "recording"))
                    .font(Theme.font(13, .semibold)).foregroundStyle(Theme.ink)
                Text(Recorder.clock(r.elapsed)).font(Theme.font(13)).monospacedDigit().foregroundStyle(Theme.muted)
            }
        }
    }

    /// Pause and Stop.
    struct Controls: View {
        @EnvironmentObject var r: Recorder
        var body: some View {
            HStack(spacing: 8) {
                Button { r.togglePause() } label: {
                    Image(systemName: r.paused ? "play.fill" : "pause.fill").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(IconPill())
                .help(r.paused ? "Resume (⌃⌥⌘P)" : "Pause, off the record (⌃⌥⌘P)")
                Button { r.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(IconPill(primary: true))
                .help("Stop and save (double-tap \(HoldKey.current.symbol))")
            }
        }
    }

    /// A round pill holding one icon: ink outline, or accent fill for Stop.
    struct IconPill: ButtonStyle {
        var primary = false
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .foregroundStyle(primary ? Theme.onAccent : Theme.ink)
                .frame(width: 28, height: 24)
                .background(Capsule().fill(primary ? Theme.accent : Theme.subtleFill))
                .overlay(Capsule().strokeBorder(primary ? Color.clear : Theme.subtleLine, lineWidth: 1))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Capsule())
        }
    }
}

/// Picks the vault project for the recording. "Decide later" lets the notes model suggest one.
struct ProjectMenu: View {
    @EnvironmentObject var r: Recorder
    var empty = "Project…"
    var urge = false

    var body: some View {
        ProjectPicker(selection: $r.project, projects: r.projects, empty: empty, urge: urge, chevron: urge && r.project.isEmpty)
    }
}

/// The bar opened out: a briefing to read, then the questions and actions earlier notes
/// left open, ticked off as the call covers them. A tick is written to the note it came from.
struct BriefPanel: View {
    @EnvironmentObject var r: Recorder
    @EnvironmentObject var b: BriefModel
    @State private var contentHeight: CGFloat = 200

    private struct HeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    /// The tallest the scrolling part may grow before it scrolls.
    private var limit: CGFloat { max(240, (NSScreen.main?.visibleFrame.height ?? 800) - 150) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                DragGrip()
                RecordingHUD.RecordingState()
                Spacer(minLength: 8)
                Button { b.open = false } label: { Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(RecordingHUD.IconPill()).help("Fold back to the bar")
                RecordingHUD.Controls()
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            rule
            ScrollView(.vertical, showsIndicators: contentHeight > limit) {
                content.background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
            }
            .frame(height: min(contentHeight, limit))
            .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
            rule
            HStack {
                Text("Visible when sharing").font(Theme.font(12)).foregroundStyle(Theme.body)
                Spacer()
                Toggle("", isOn: $b.visibleWhenSharing).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .help("Off: this brief is left out of your screen share. The small bar is always shown.")
        }
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.ground))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.subtleLine, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }

    private var rule: some View { Rectangle().fill(Theme.rule).frame(height: 1) }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading
            if !b.briefingFolded { briefing }
            if !b.questions.isEmpty { rule; list("Open questions", b.questions) }
            if !b.actions.isEmpty { rule; list("Actions to chase", b.actions) }
            if b.questions.isEmpty && b.actions.isEmpty {
                rule
                Text(b.hasNotes ? "Earlier notes left nothing open." : "No earlier notes for this project yet.")
                    .font(Theme.font(13, .light)).foregroundStyle(Theme.muted).padding(16)
            }
        }
        .frame(width: 340, alignment: .leading)
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if b.briefingFolded {
                ProjectPicker(selection: $r.project, projects: r.projects, empty: "Choose project", size: 15).padding(.leading, -4)
                Text("Briefing").font(Theme.font(12)).foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ProjectPicker(selection: $r.project, projects: r.projects, empty: "Choose project", size: 17).padding(.leading, -4)
                    if let d = b.lastMet { Text("Last met \(Self.day(d))").font(Theme.font(12)).foregroundStyle(Theme.muted) }
                }
            }
            Spacer(minLength: 8)
            if b.briefing != nil || b.writingBriefing {
                Button { b.briefingFolded.toggle() } label: {
                    Image(systemName: b.briefingFolded ? "chevron.down" : "chevron.up").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.body).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(b.briefingFolded ? "Show the briefing" : "Fold the briefing away")
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, b.briefingFolded ? 14 : 10)
    }

    @ViewBuilder private var briefing: some View {
        if let br = b.briefing {
            VStack(alignment: .leading, spacing: 10) {
                if !br.aim.isEmpty {
                    Text("Today: \(br.aim)").font(Theme.font(14, .medium)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(br.points, id: \.self) { p in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle().fill(Theme.muted).frame(width: 4, height: 4).frame(width: 18).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                        Text(p).font(Theme.font(13, .light)).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        } else if b.writingBriefing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Writing the briefing…").font(Theme.font(12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    private func list(_ title: String, _ items: [BriefItem]) -> some View {
        let left = items.filter { !$0.done }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(Theme.font(12, .semibold)).foregroundStyle(Theme.body)
                Spacer()
                Text(left == items.count ? "\(left)" : "\(left) of \(items.count) left").font(Theme.font(12)).foregroundStyle(Theme.muted)
            }
            ForEach(items) { item in BriefRow(item: item) { b.toggle(item) } }
        }
        .padding(16)
    }

    static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_GB"); f.dateFormat = "d MMM"
        return f.string(from: d)
    }
}

/// One question or action with its tick. The tick and the text share one fixed column each,
/// so rows line up whatever their length.
struct BriefRow: View {
    let item: BriefItem
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    if item.done {
                        Circle().fill(Theme.subtleOn)
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.body)
                    } else {
                        Circle().strokeBorder(Theme.outline, lineWidth: 1.5)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).font(Theme.font(14)).strikethrough(item.done)
                        .foregroundStyle(item.done ? Theme.muted : Theme.ink)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if !item.done && item.kind == .action {
                        (Text(item.owner.isEmpty ? "" : "\(item.owner) · ").foregroundColor(Theme.muted)
                            + Text(item.due).foregroundColor(item.overdue ? Theme.accentText : Theme.muted))
                            .font(Theme.font(12))
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
