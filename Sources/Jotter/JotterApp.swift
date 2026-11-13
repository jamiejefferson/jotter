import SwiftUI

@main
enum Entry {
    static func main() {
        Theme.registerFonts()
        if CommandLine.arguments.dropFirst().first == "--file-check", CommandLine.arguments.count > 3 {
            MainActor.assumeIsolated { FileCheck.run(recording: URL(fileURLWithPath: CommandLine.arguments[2]), folder: URL(fileURLWithPath: CommandLine.arguments[3])) }
            return
        }
        if CommandLine.arguments.dropFirst().first == "--mic-users" {
            MainActor.assumeIsolated {
                if let pid = CommandLine.arguments.dropFirst(2).first.flatMap({ pid_t($0) }) {
                    let o = CallWatcher.owner(pid: pid, bundleID: ""); print(o.id ?? "-", "|", o.name, o.system ? "(system, ignored)" : "")
                } else { for u in CallWatcher.micUsers() { print(u.key, "|", u.name) } }
            }
            return
        }
        if CommandLine.arguments.dropFirst().first == "--render-check", CommandLine.arguments.count > 2 {
            // Renders the wordmark and controls to PNGs for a visual check.
            MainActor.assumeIsolated { RenderCheck.run(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
            return
        }
        if SelfTest.run(CommandLine.arguments) { return }
        if Transcribe.run(CommandLine.arguments) { return }
        for (flag, name) in [("--show-settings", "com.eqtr.jotter.showSettings"), ("--show-feedback", "com.eqtr.jotter.showFeedback"),
                             ("--check-update", "com.eqtr.jotter.checkUpdate"), ("--install-update", "com.eqtr.jotter.installUpdate")]
        where CommandLine.arguments.dropFirst().first == flag {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: nil, deliverImmediately: true)
            return
        }
        if CommandLine.arguments.dropFirst().first == "--show-meetings" {
            DistributedNotificationCenter.default().postNotificationName(MeetingsWindow.showRequest, object: nil, deliverImmediately: true)
            return
        }
        JotterApp.main()
    }
}

struct JotterApp: App {
    // Shared so Settings can open from outside the panel (`Jotter --show-settings`).
    @MainActor static let recorder = Recorder()
    @MainActor static let dictation = Dictation()
    @ObservedObject private var recorder = JotterApp.recorder
    @ObservedObject private var dictation = JotterApp.dictation
    @ObservedObject private var updater = Updater.shared

    init() {
        MeetingsWindow.listen()
        Notifier.shared.install()
        Updater.shared.start()
        CallWatcher.shared.start()
        for (name, open) in [("com.eqtr.jotter.showSettings", { @MainActor in JotterApp.showSettings() }),
                             ("com.eqtr.jotter.showFeedback", { @MainActor in SettingsWindow.feedback.show(FeedbackView()) }),
                             ("com.eqtr.jotter.checkUpdate", { @MainActor in Updater.shared.checkNow() }),
                             ("com.eqtr.jotter.installUpdate", { @MainActor in Updater.shared.install() })] {
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                Task { @MainActor in open() }
            }
        }
    }

    @MainActor static func showSettings() {
        SettingsWindow.shared.show(SettingsView().environmentObject(recorder).environmentObject(dictation))
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView().environmentObject(recorder).environmentObject(dictation)
        } label: {
            if dictation.state == .listening {
                Image(systemName: "mic.fill")
            } else if let _ = recorder.kind {
                Text("\(Image(systemName: recorder.paused ? "pause.circle" : "record.circle.fill")) \(Recorder.clock(recorder.elapsed))")
            } else if recorder.saving {
                Image(systemName: "arrow.down.circle")
            } else if updater.available != nil {
                // A dot on the icon says an update is waiting.
                Image(systemName: "waveform.badge.exclamationmark")
            } else {
                Image(systemName: "waveform")
            }
        }
        .menuBarExtraStyle(.window)

    }
}

struct PanelView: View {
    @EnvironmentObject var r: Recorder
    @EnvironmentObject var d: Dictation
    @ObservedObject private var u = Updater.shared
    private func showMeetings() { MeetingsWindow.shared.show() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Wordmark(size: 22)
                Spacer()
                Button("Meetings") { showMeetings() }.buttonStyle(PillButtonStyle(small: true))
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)
            Rectangle().fill(Theme.rule).frame(height: 1)

            if let release = u.available { updateCard(release) }
            VStack(alignment: .leading, spacing: 14) {
                if let kind = r.kind { recording(kind) } else { idle }

                if r.saving || r.transcribing || r.writingNotes {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(r.saving ? "Saving…" : r.transcribing ? "Transcribing on this Mac…" : "Writing notes…")
                            .font(Theme.secondary).foregroundStyle(Theme.body)
                    }
                }
                if let m = r.message { warning(m) }
                if r.micBlocked {
                    warning("Jotter can't use the microphone. Turn it on in System Settings, then try again.")
                    Button("Open Microphone settings") { r.openMicSettings() }.buttonStyle(PillButtonStyle(small: true))
                }
                if let last = r.last, !r.isRecording { lastSaved(last) }
            }
            .padding(24)
            Rectangle().fill(Theme.rule).frame(height: 1)
            dictationSection.padding(24)
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack(spacing: 16) {
                Button("Settings") { JotterApp.showSettings() }
                    .buttonStyle(QuietButtonStyle())
                Button("Feedback") { SettingsWindow.feedback.show(FeedbackView()) }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Recordings") { r.openRecordings() }.buttonStyle(QuietButtonStyle())
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Theme.rail)
        }
        .font(Theme.text)
        .foregroundStyle(Theme.ink)
        .background(Theme.ground)
        .frame(width: 360)
        .environment(\.colorScheme, .dark)
    }

    private func updateCard(_ release: Updater.Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Dot()
                Text("Jotter \(release.version) is ready").font(Theme.font(14, .semibold))
                Spacer()
                Button(u.updating ? "Updating…" : "Update now") { u.install() }
                    .buttonStyle(PillButtonStyle(primary: true, small: true)).disabled(u.updating)
            }
            if !release.notes.isEmpty {
                Text(release.notes).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let p = u.problem { Text(p).font(Theme.meta).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true) }
            Text("You're on \(Updater.current). Jotter closes and reopens in a few seconds.").font(Theme.meta).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(Theme.zone)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(Theme.secondary).foregroundStyle(Theme.redText).fixedSize(horizontal: false, vertical: true)
    }

    private func sectionHead(_ title: String, _ status: String? = nil) -> some View {
        HStack {
            Text(title).font(Theme.h2).tracking(-0.6)
            Spacer()
            if let status { Text(status).font(Theme.meta).foregroundStyle(Theme.muted) }
        }
    }

    private var dictationSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHead("Dictation", d.state == .listening ? "Listening" : d.state == .finishing ? "Writing" : d.state == .off ? "Starting" : "Ready")
            KeyHints()
            if !d.trusted {
                warning("Allow Jotter under Accessibility so it can hear the key and paste for you.")
                Button("Allow in Accessibility") { d.askForAccessibility() }.buttonStyle(PillButtonStyle(primary: true, small: true))
            }
            if !d.lastText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\u{201C}\(d.lastText)\u{201D}").font(Theme.secondary).foregroundStyle(Theme.body).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let delay = d.lastDelay {
                        Text(String(format: "Pasted %.1f s after you let go", delay)).font(Theme.meta).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.rule).frame(width: 2) }
            }
            if let m = d.message { warning(m) }
            if ModelAccess.route() == nil {
                warning("Add an OpenRouter key in Settings so Jotter can write meeting notes and tidy dictation.")
            }
        }
    }

    private func keyLine(_ key: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(Theme.font(12, .semibold)).frame(width: 118, alignment: .leading)
            Text(what).font(Theme.secondary).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHead("Record")
            Button { r.start(.meeting) } label: {
                Label("Record meeting", systemImage: "record.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(primary: true))
            .disabled(r.saving)
            Button { r.start(.note) } label: {
                Label("Record note", systemImage: "mic").frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle())
            .disabled(r.saving)
            Text("Meetings: double-tap \(d.holdKey.symbol) or ⌃⌥⌘J. Notes: ⌃⌥⌘N.").font(Theme.meta).foregroundStyle(Theme.muted)
        }
    }

    private func recording(_ kind: Kind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Dot(color: r.paused ? Theme.muted : Theme.dot)
                Text(r.paused ? "Paused" : kind == .meeting ? "Recording meeting" : "Recording note").font(Theme.h2).tracking(-0.6)
                Spacer()
                Text(Recorder.clock(r.elapsed)).font(Theme.font(15, .medium)).monospacedDigit()
            }
            LevelRow(title: "You (microphone)", level: r.micLevel)
            if kind == .meeting {
                LevelRow(title: "Call audio", level: r.callLevel)
                if !r.callHeard && r.elapsed > 10 {
                    Text("No call audio yet. If the call is playing, allow Jotter under Screen & System Audio Recording.")
                        .font(Theme.meta).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Open settings") { r.openAudioCaptureSettings() }.buttonStyle(QuietButtonStyle())
                }
            }
            TextField("Name this recording (optional)", text: $r.label)
                .textFieldStyle(.plain)
                .font(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.subtleLine))
                .onSubmit { r.stop() }
            HStack(spacing: 8) {
                Text("Project").font(Theme.secondary).foregroundStyle(Theme.muted)
                ProjectMenu()
                Spacer()
            }
            HStack(spacing: 8) {
                Button(r.paused ? "Resume" : "Pause") { r.togglePause() }
                    .buttonStyle(PillButtonStyle())
                    .help("Pause goes off the record without ending the meeting · ⌃⌥⌘P")
                Button { r.stop() } label: { Label("Stop and save", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle(primary: true))
            }
        }
    }

    private func lastSaved(_ s: Saved) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StatusPill(text: "Saved", style: .solid)
                Text("\(s.kind == .meeting ? "Meeting" : "Note") · \(Recorder.clock(s.seconds))").font(Theme.secondary)
                Spacer()
                Button("Show") { r.reveal(s.folder) }.buttonStyle(QuietButtonStyle())
            }
            if s.kind == .meeting && (s.transcript != nil || s.note != nil) {
                Button(s.note != nil ? "Review notes" : "Review meeting") { showMeetings() }.buttonStyle(PillButtonStyle(small: true))
            } else if let t = s.transcript {
                Button("Open transcript") { r.open(t) }.buttonStyle(PillButtonStyle(small: true))
            }
            if let w = s.warning { Text(w).font(Theme.meta).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
        .card(padding: 14)
    }
}

/// One option in a row of choices: ink fill when chosen, outline otherwise (Canon's tabs as pills).
struct SegmentStyle: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(12, on ? .semibold : .regular))
            .padding(.horizontal, 14).padding(.vertical, 4)
            .foregroundStyle(on ? Theme.ink : Theme.muted)
            .background(Capsule().fill(on ? Theme.subtleOn : Color.clear))
            .overlay(Capsule().strokeBorder(Theme.subtleLine))
            .contentShape(Capsule())
    }
}

struct LevelRow: View {
    let title: String
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.meta).foregroundStyle(Theme.muted)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.zone)
                    Capsule().fill(level > 0.9 ? Theme.accent : Theme.ink)
                        .frame(width: max(4, g.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.1), value: level)
                }
            }
            .frame(height: 4)
        }
    }
}

@MainActor
enum RenderCheck {
    static func run(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sample = VStack(alignment: .leading, spacing: 18) {
            Wordmark(size: 30)
            Wordmark(size: 22)
            HStack(spacing: 8) {
                Button("Record meeting") {}.buttonStyle(PillButtonStyle(primary: true))
                Button("Record note") {}.buttonStyle(PillButtonStyle())
                Button("Meetings") {}.buttonStyle(PillButtonStyle(small: true))
            }
            HStack(spacing: 6) {
                StatusPill(text: "Saved", style: .solid); StatusPill(text: "You", style: .accent)
                StatusPill(text: "Grant", style: .outline); StatusPill(text: "suggested", style: .dashed)
                Dot(); Text("Needs filing").font(Theme.meta).foregroundStyle(Theme.redText)
            }
            Text("Card text in body grey").font(Theme.secondary).foregroundStyle(Theme.body).card()
            ConnectionSection().frame(width: 312)
            KeyHints()
        }
        .padding(24).background(Theme.ground).environment(\.colorScheme, .dark)
        for (name, view, scale) in [("sample", AnyView(sample), 2.0), ("wordmark-x8", AnyView(Wordmark(size: 30).padding(4).background(Theme.ground)), 8.0)] {
            let r = ImageRenderer(content: view); r.scale = scale
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
                print(dir.appendingPathComponent("\(name).png").path)
            }
        }
    }
}
