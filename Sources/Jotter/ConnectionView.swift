import AppKit
import SwiftUI

/// The panel's model connection: shows which route Jotter uses and lets a person add,
/// check and remove their own OpenRouter key.
@MainActor
final class ConnectionModel: ObservableObject {
    @Published var entering = false
    @Published var draft = ""
    @Published var checking = false
    @Published var problem: String?
    @Published private(set) var route: ModelAccess.Route?

    init() { route = ModelAccess.route() }

    func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        checking = true
        problem = nil
        Task {
            let issue = await ModelAccess.check(key)
            checking = false
            if let issue { problem = issue; return }
            ModelAccess.saveOpenRouterKey(key)
            draft = ""
            entering = false
            route = ModelAccess.route()
        }
    }

    func remove() {
        ModelAccess.removeOpenRouterKey()
        route = ModelAccess.route()
    }
}

struct ConnectionSection: View {
    @StateObject private var c = ConnectionModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Connection").font(Theme.h2).tracking(-0.6)
                Spacer()
                if let r = c.route {
                    HStack(spacing: 6) { Dot(color: Theme.muted); Text(r.name).font(Theme.meta).foregroundStyle(Theme.muted) }
                } else {
                    HStack(spacing: 6) { Dot(); Text("Not connected").font(Theme.meta).foregroundStyle(Theme.muted) }
                }
            }
            Text(summary).font(Theme.secondary).foregroundStyle(Theme.body).fixedSize(horizontal: false, vertical: true)

            if c.entering {
                SecureField("sk-or-…", text: $c.draft)
                    .textFieldStyle(.plain).font(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.subtleLine))
                    .onSubmit { c.save() }
                HStack(spacing: 8) {
                    Button(c.checking ? "Checking…" : "Save key") { c.save() }
                        .buttonStyle(PillButtonStyle(primary: true, small: true))
                        .disabled(c.checking || c.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { c.entering = false; c.draft = ""; c.problem = nil }.buttonStyle(PillButtonStyle(small: true))
                    Spacer()
                    Button("Get a key") { NSWorkspace.shared.open(URL(string: "https://openrouter.ai/keys")!) }
                        .buttonStyle(QuietButtonStyle())
                }
            } else {
                HStack(spacing: 8) {
                    if ModelAccess.openRouterKey() != nil {
                        Button("Change key") { c.entering = true }.buttonStyle(PillButtonStyle(small: true))
                        Button("Remove") { c.remove() }.buttonStyle(PillButtonStyle(small: true))
                    } else {
                        Button("Add OpenRouter key") { c.entering = true }
                            .buttonStyle(PillButtonStyle(primary: c.route == nil, small: true))
                    }
                }
            }
            if let p = c.problem { Text(p).font(Theme.secondary).foregroundStyle(Theme.redText).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private var summary: String {
        switch c.route?.name {
        case "OpenRouter":
            let k = ModelAccess.openRouterKey() ?? ""
            return "Notes and tidying use your OpenRouter key (ending \(k.suffix(4))), billed to your account. Jotter asks OpenRouter for providers that don't store or train on what you send."
        case "KeyBus":
            return "Notes and tidying go through KeyBus. Add your own OpenRouter key to use that instead."
        default:
            return "Add an OpenRouter key so Jotter can write meeting notes and tidy dictation. Recording, transcripts and Light tidying work without one."
        }
    }
}
