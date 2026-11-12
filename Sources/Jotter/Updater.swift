import AppKit
import UserNotifications

/// Checks GitHub for a newer Jotter release, tells the person with a Mac notification and a
/// card in the panel, and installs it in place on request: download, check the signature,
/// swap the app and reopen. It never swaps while a meeting is recording or its notes are
/// still being written.
@MainActor
final class Updater: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Updater()
    static let repo = "jamiejefferson/jotter"

    struct Release { let version: String; let notes: String }

    @Published private(set) var available: Release?
    @Published private(set) var updating = false
    @Published var problem: String?

    private var timer: Timer?
    private var pendingInstall = false

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Starts checking: shortly after launch, then every four hours.
    func start() {
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { Task { await self.check() } }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check() }
        }
    }

    func checkNow() { Task { await check() } }

    func check() async {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!, timeoutInterval: 20)
        req.setValue("Jotter", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: Self.current) else { available = nil; return }
        available = Release(version: version, notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        notifyOnce(version)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// One Mac notification per new version.
    private func notifyOnce(_ version: String) {
        let key = "notifiedUpdate"
        guard UserDefaults.standard.string(forKey: key) != version else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "Jotter \(version) is ready"
            c.body = "Click to update. Jotter reopens in a few seconds."
            let r = UNNotificationRequest(identifier: "jotter-update-\(version)", content: c, trigger: nil)
            center.add(r)
            DispatchQueue.main.async { UserDefaults.standard.set(version, forKey: key) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { Updater.shared.install() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// True while a recording or its notes would be lost by restarting.
    private var busy: Bool {
        let r = JotterApp.recorder
        return r.isRecording || r.saving || r.transcribing || r.writingNotes
    }

    func install() {
        guard !updating else { return }
        if busy {
            problem = "Jotter will update when this meeting's notes are written."
            pendingInstall = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let self, self.pendingInstall else { return }
                self.pendingInstall = false
                self.install()
            }
            return
        }
        pendingInstall = false
        updating = true
        problem = nil
        Task {
            do {
                try await swapAndRelaunch()
            } catch {
                problem = "Update failed: \(error.localizedDescription)"
                updating = false
            }
        }
    }

    private func swapAndRelaunch() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("jotter-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let zipURL = URL(string: "https://github.com/\(Self.repo)/releases/latest/download/Jotter.zip")!
        let (downloaded, resp) = try await URLSession.shared.download(from: zipURL)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure("the download didn't arrive") }
        let zip = tmp.appendingPathComponent("Jotter.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path])
        let fresh = tmp.appendingPathComponent("Jotter.app")
        // Only swap in an app that is intact and signed by the same certificate as this one.
        try run("/usr/bin/codesign", ["--verify", "--strict", fresh.path])
        try run("/usr/bin/codesign", ["--verify", "-R=" + designatedRequirement(), fresh.path])

        let target = Bundle.main.bundleURL
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf '\(target.path)'
        mv '\(fresh.path)' '\(target.path)'
        xattr -dr com.apple.quarantine '\(target.path)' 2>/dev/null
        open '\(target.path)'
        rm -rf '\(tmp.path)'
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
    }

    private func designatedRequirement() throws -> String {
        var code: SecStaticCode?
        var req: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req,
              SecRequirementCopyString(req, [], &text) == errSecSuccess, let text else { throw Failure("couldn't read this app's signature") }
        return text as String
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("\((tool as NSString).lastPathComponent) failed") }
        return p.terminationStatus
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }
}
