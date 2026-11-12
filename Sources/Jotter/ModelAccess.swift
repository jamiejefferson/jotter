import Foundation
import Security

/// How Jotter reaches the models that write notes and tidy dictation. A person's own
/// OpenRouter key comes first, so anyone at Equator can use Jotter today; KeyBus is the
/// fallback where a KeyBus key exists. Every request asks OpenRouter to use only providers
/// that neither store nor train on what is sent, whichever route carries it.
enum ModelAccess {
    struct Route {
        let url: URL
        let key: String
        let name: String
    }

    static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    static let keyBusURL = URL(string: "https://keybus.projject.ai/openrouter/v1/chat/completions")!
    private static let service = "com.eqtr.jotter.openrouter"

    /// The route to use now, or nil when nothing is connected.
    static func route() -> Route? {
        if let k = openRouterKey() { return Route(url: openRouterURL, key: k, name: "OpenRouter") }
        if let k = Cleanup.keyBusKey() { return Route(url: keyBusURL, key: k, name: "KeyBus") }
        return nil
    }

    static let notConnected = "Jotter isn't connected to a model. Add your OpenRouter key in the Jotter panel."

    /// A POST request to the chat endpoint on the current route.
    static func request(timeout: TimeInterval = 60) throws -> URLRequest {
        guard let r = route() else { throw Failure(errorDescription: notConnected) }
        var req = URLRequest(url: r.url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(r.key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        // OpenRouter shows this name on its activity page, so people can tell Jotter's calls apart.
        req.setValue("Jotter", forHTTPHeaderField: "X-Title")
        return req
    }

    struct Failure: LocalizedError { let errorDescription: String? }

    // MARK: The person's own OpenRouter key, kept in Jotter's key file

    static func openRouterKey() -> String? { KeyFile.read("openrouter") }

    static func saveOpenRouterKey(_ key: String) { KeyFile.write("openrouter", key) }

    static func removeOpenRouterKey() {
        KeyFile.remove("openrouter")
        // Builds before 0.6.1 kept it in the Keychain; clear that copy too.
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "openrouter"]
        SecItemDelete(q as CFDictionary)
    }

    /// Asks OpenRouter whether a key works before saving it. Returns nil when it does,
    /// or a sentence saying what is wrong.
    static func check(_ key: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!, timeoutInterval: 15)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return nil
            case 401, 403: return "OpenRouter didn't accept that key. Check it at openrouter.ai/keys."
            case let s: return "OpenRouter answered with an error (HTTP \(s)). Try again in a minute."
            }
        } catch {
            return "Couldn't reach OpenRouter: \(error.localizedDescription)"
        }
    }
}

/// Keys Jotter keeps for itself, in files only this Mac user can read
/// (`~/Library/Application Support/Jotter/Keys/`, folder 700, files 600).
/// The Keychain asked for the login password after every rebuild: macOS ties a Keychain
/// item to the exact build of an app that has no Apple Developer team ID, so each new
/// version counted as a stranger. Files survive updates without asking.
enum KeyFile {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Jotter/Keys", isDirectory: true)
    }()

    static func read(_ name: String) -> String? {
        guard let s = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) else { return nil }
        let k = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    static func write(_ name: String, _ key: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let url = folder.appendingPathComponent(name)
        fm.createFile(atPath: url.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
}
