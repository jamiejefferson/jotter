import AppKit
import SwiftUI

/// Settings: who you are, where notes go, the model connection and the dictation options.
struct SettingsView: View {
    @EnvironmentObject var r: Recorder
    @EnvironmentObject var d: Dictation
    @StateObject private var p = ProfileModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("You") {
                    field("Name", text: $p.name, hint: "Used so the notes know which actions are yours.")
                    field("Also known as", text: $p.aka, hint: "Nicknames or initials people use in meetings, separated by commas.")
                    VStack(alignment: .leading, spacing: 6) {
                        label("About you")
                        TextEditor(text: $p.about)
                            .font(Theme.text).scrollContentBackground(.hidden)
                            .padding(6).frame(height: 72)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.subtleLine))
                        hint("Your role and anything the notes should know, such as which meetings belong to which project.")
                    }
                }
                section("Notes folder") {
                    Text(p.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(Theme.secondary).foregroundStyle(Theme.body).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button("Change…") { chooseFolder() }.buttonStyle(PillButtonStyle(small: true))
                        Button("Show in Finder") { NSWorkspace.shared.open(p.folder) }.buttonStyle(PillButtonStyle(small: true))
                    }
                    hint("Notes are filed in Projects/<project>/Meetings inside this folder, or Meetings/Needs filing when the project is unclear. An Obsidian vault works well.")
                }
                section(nil) { ConnectionSection() }
                section("Dictation") {
                    label("Key")
                    HStack(spacing: 6) {
                        ForEach(HoldKey.allCases) { k in Button(k.label) { d.holdKey = k }.buttonStyle(SegmentStyle(on: d.holdKey == k)) }
                    }
                    if let note = d.holdKey.note { hint(note) }
                    label("Tidying").padding(.top, 4)
                    HStack(spacing: 6) {
                        ForEach(Tidying.allCases) { t in Button(t.label) { d.tidying = t }.buttonStyle(SegmentStyle(on: d.tidying == t)) }
                    }
                    hint(d.tidying.detail)
                    HStack(spacing: 14) {
                        if d.tidying == .tidy { Button("Tidying instructions") { d.openTidyingInstructions() }.buttonStyle(QuietButtonStyle()) }
                        Button("Name fixes") { d.openVocabulary() }.buttonStyle(QuietButtonStyle())
                    }
                    Toggle("Keep a dictation log on this Mac", isOn: $d.keepLog).toggleStyle(.checkbox).font(Theme.secondary)
                }
                section("General") {
                    Toggle("Open at login", isOn: $r.openAtLogin).toggleStyle(.checkbox).font(Theme.secondary)
                }
            }
            .padding(.vertical, 8)
        }
        .font(Theme.text)
        .foregroundStyle(Theme.ink)
        .background(Theme.ground)
        .frame(width: 520)
        .frame(height: 680)
        .environment(\.colorScheme, .dark)
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = self.p.folder
        p.prompt = "Use this folder"
        p.message = "Choose the folder Jotter files meeting notes in."
        p.beginSheetModal(for: SettingsWindow.shared.window ?? NSWindow()) { resp in
            guard resp == .OK, let url = p.url else { return }
            self.p.folder = url
        }
    }

    @ViewBuilder private func section(_ title: String?, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(Theme.h2).tracking(-0.6) }
            content()
        }
        .padding(.horizontal, 32).padding(.vertical, 22)
        Rectangle().fill(Theme.rule).frame(height: 1)
    }

    private func label(_ s: String) -> some View { Text(s).font(Theme.kind).foregroundStyle(Theme.muted) }
    private func hint(_ s: String) -> some View { Text(s).font(Theme.meta).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }

    private func field(_ title: String, text: Binding<String>, hint h: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            label(title)
            TextField("", text: text)
                .textFieldStyle(.plain).font(Theme.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.subtleLine))
            hint(h)
        }
    }
}

/// The settings fields, saved to `Profile` as they change.
@MainActor
final class ProfileModel: ObservableObject {
    @Published var name = Profile.name { didSet { Profile.name = name } }
    @Published var aka = Profile.alsoKnownAs { didSet { Profile.alsoKnownAs = aka } }
    @Published var about = Profile.about { didSet { Profile.about = about } }
    @Published var folder = Profile.notesFolder { didSet { Profile.notesFolder = folder } }
}

/// Sends feedback to Supabase, where JJ reads and triages it.
@MainActor
final class FeedbackModel: ObservableObject {
    @Published var text = ""
    @Published var kind = "feedback"
    @Published var includeName = true
    @Published var sending = false
    @Published var result: String?

    static let endpoint = URL(string: "https://xlswtyprnmiymfjdbaez.supabase.co/rest/v1/jotter_feedback")!
    /// Supabase's publishable key: it can only add feedback rows, never read them.
    static let publishableKey = "sb_publishable_ISmJRrzDN3Z6OEdEEZe2Cw_5YvSDGkt"

    func send() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        sending = true; result = nil
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var row: [String: Any] = ["text": String(body.prefix(5000)), "feedback_type": kind, "app_version": version,
                                  "os_version": ProcessInfo.processInfo.operatingSystemVersionString]
        if includeName { row["name"] = String(Profile.name.prefix(120)) }
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: row)
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 201 { text = ""; result = "Sent. Thank you." } else { result = "Couldn't send (HTTP \(code)). Try again later." }
            } catch { result = "Couldn't send: \(error.localizedDescription)" }
            sending = false
        }
    }
}

struct FeedbackView: View {
    @StateObject private var f = FeedbackModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send feedback").font(Theme.h2).tracking(-0.6)
            Text("Tell us what's broken, confusing or missing. It goes straight to the people building Jotter.")
                .font(Theme.secondary).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach([("feedback", "Feedback"), ("bug", "Something's broken"), ("idea", "Idea")], id: \.0) { k, l in
                    Button(l) { f.kind = k }.buttonStyle(SegmentStyle(on: f.kind == k))
                }
            }
            TextEditor(text: $f.text)
                .font(Theme.text).scrollContentBackground(.hidden)
                .padding(8).frame(minHeight: 140)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.subtleLine))
            Toggle("Include my name (\(Profile.name))", isOn: $f.includeName).toggleStyle(.checkbox).font(Theme.secondary)
            HStack {
                if let r = f.result { Text(r).font(Theme.secondary).foregroundStyle(Theme.body) }
                Spacer()
                Button(f.sending ? "Sending…" : "Send") { f.send() }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .disabled(f.sending || f.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Only what you type here is sent, with Jotter's version and your macOS version. Never recordings or notes.")
                .font(Theme.meta).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .font(Theme.text)
        .foregroundStyle(Theme.ink)
        .background(Theme.ground)
        .frame(width: 480)
        .environment(\.colorScheme, .dark)
    }
}

/// Small dark windows for Settings and Feedback, opened from the panel.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow(title: "Jotter settings")
    static let feedback = SettingsWindow(title: "Jotter feedback")
    private(set) var window: NSWindow?
    private let title: String
    private init(title: String) { self.title = title }

    func show<V: View>(_ view: V) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                             styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = title
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.appearance = Theme.appearance
            w.backgroundColor = Theme.groundNS
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: AnyView(view))
            host.sizingOptions = [.preferredContentSize]
            w.contentViewController = host
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
