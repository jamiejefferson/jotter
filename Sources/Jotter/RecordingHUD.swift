import AppKit
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
@MainActor
final class RecordingHUD {
    private var panel: NSPanel?
    private let recorder: Recorder

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
            let host = NSHostingController(rootView: AnyView(Bar().environmentObject(recorder)))
            host.sizingOptions = [.preferredContentSize]
            p.contentViewController = host
            p.appearance = Theme.appearance
            if !p.setFrameUsingName("JotterRecordingBar"), let screen = NSScreen.main {
                let size = p.contentView?.fittingSize ?? NSSize(width: 360, height: 44)
                let f = screen.visibleFrame
                p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - size.height - 12, width: size.width, height: size.height), display: true)
            }
            p.setFrameAutosaveName("JotterRecordingBar")
            panel = p
        }
        if let panel, let size = panel.contentView?.fittingSize {
            panel.setContentSize(size)
        }
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    struct Bar: View {
        @EnvironmentObject var r: Recorder

        var body: some View {
            if r.kind == nil && r.showingResult { result } else { recording }
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
                Dot(color: r.paused ? Theme.muted : Theme.dot)
                    // Blinks about once a second while recording, driven by the recording clock.
                    .opacity(r.paused || Int(r.elapsed * 1.25) % 2 == 0 ? 1 : 0.3)
                Text(r.paused ? "paused" : (r.kind == .note ? "note" : "recording"))
                    .font(Theme.font(13, .semibold)).foregroundStyle(Theme.ink)
                Text(Recorder.clock(r.elapsed)).font(Theme.font(13)).monospacedDigit().foregroundStyle(Theme.muted)
                Rectangle().fill(Theme.rule).frame(width: 1, height: 16)
                ProjectMenu()
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
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 7)
            .background(Capsule().fill(Theme.ground))
            .overlay(Capsule().strokeBorder(Theme.subtleLine, lineWidth: 1))
            .fixedSize()
            .environment(\.colorScheme, .dark)
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

    var body: some View {
        let projects = r.projects
        Menu {
            Button("Decide later") { r.project = "" }
            Divider()
            ForEach(projects.prefix(12), id: \.self) { p in Button(p) { r.project = p } }
            if projects.count > 12 {
                Menu("All projects") {
                    ForEach(projects.sorted(), id: \.self) { p in Button(p) { r.project = p } }
                }
            }
        } label: {
            Text(r.project.isEmpty ? "Project…" : r.project).font(Theme.font(12)).foregroundStyle(r.project.isEmpty ? Theme.muted : Theme.ink).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
