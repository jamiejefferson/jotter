import AppKit
import CoreAudio
import UserNotifications

/// Gently suggests notes for meetings. A few minutes before a calendar meeting, or when
/// another app (Teams, Zoom, a browser on Google Meet) has held the microphone for a little
/// while and Jotter isn't recording, a card asks whether to record. When a recording is running and the call app lets
/// go of the mic, one notification offers to stop and write the notes.
@MainActor
final class CallWatcher {
    static let shared = CallWatcher()

    /// Apps that use the mic without being a meeting, or that run alongside one (Granola).
    /// macOS's own dictation and Siri run as system processes outside any app and are skipped
    /// by `owner(pid:)`.
    private static let ignored: Set<String> = [
        "com.eqtr.jotter", "com.apple.VoiceMemos", "com.electron.wispr-flow", "com.granola.app",
    ]
    static let promptAfter: TimeInterval = 15
    static let endedAfter: TimeInterval = 45

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "suggestRecording") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "suggestRecording") }
    }

    private var timer: Timer?
    /// When each app (by bundle id or name) was first seen holding the mic in this stretch.
    private var since: [String: Date] = [:]
    /// Apps already asked about during their current call.
    private var asked: Set<String> = []
    /// The call app seen while this recording runs, and when the mic was last busy.
    private var callDuringRecording: String?
    private var lastCallSeen: Date?
    private var offeredStop = false
    /// The app named in the last "Jot notes?" prompt.
    private var lastPrompted: String?
    /// Calendar meetings already offered, so each is asked about once.
    private var offered: Set<String> = []
    /// The previous check, and the sleep the Mac last woke from.
    private var lastTick: Date?
    private var sleptFrom: Date?
    private var wokeAt: Date?

    /// Called when Record is pressed on the prompt, so the end of that call is noticed even
    /// if the call app lets go of the mic before the next check.
    func recordingStartedFromPrompt() {
        callDuringRecording = lastPrompted
        lastCallSeen = Date()
        offeredStop = false
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in CallWatcher.shared.tick() }
        }
    }

    private func tick() {
        let users = Self.micUsers()
        let now = Date()
        // The list a sleeping Mac woke with can be stale, so a meeting missed in sleep is
        // looked for on each check for a minute after the lid opens.
        if let l = lastTick, now.timeIntervalSince(l) > 60 { sleptFrom = l; wokeAt = now }
        lastTick = now
        let lastCheck = wokeAt.map { now.timeIntervalSince($0) < 60 } == true ? sleptFrom : now
        // Forget apps that let go, so their next call can be asked about again.
        for key in since.keys where !users.contains(where: { $0.key == key }) { since[key] = nil; asked.remove(key) }
        for u in users where since[u.key] == nil { since[u.key] = now }

        let recorder = JotterApp.recorder
        Agenda.shared.refreshIfDue()
        if recorder.isRecording && recorder.kind == .meeting {
            if let u = users.first {
                callDuringRecording = u.name
                lastCallSeen = now
            } else if let name = callDuringRecording, let last = lastCallSeen, !offeredStop,
                      now.timeIntervalSince(last) > Self.endedAfter {
                offeredStop = true
                Notifier.post(id: Notifier.callEnded, title: "Has the call ended?",
                              body: "\(name) has stopped using the microphone. Stop recording and write the notes?",
                              category: Notifier.callEnded)
            }
            return
        }
        // A voice note is running: leave it alone.
        if recorder.isRecording { return }
        // Not recording: reset the stop offer for next time.
        if offeredStop { Notifier.clear(Notifier.callEnded) }
        callDuringRecording = nil; lastCallSeen = nil; offeredStop = false
        // Once the call that was asked about has ended, its prompt is stale.
        if users.isEmpty && lastPrompted != nil { PromptCard.shared.withdrawMicPrompt(); lastPrompted = nil }
        guard Self.enabled, !recorder.saving else { return }
        // A calendar meeting is about to start: offer to record it, once.
        if PromptCard.shared.stage == .hidden, let e = Agenda.shared.starting(at: now, since: lastCheck) {
            let key = "\(e.title)|\(e.start.timeIntervalSince1970)"
            if offered.insert(key).inserted {
                Notifier.log("card: \(e.title) at \(PromptCard.time(e.start))")
                PromptCard.shared.ask(event: e, app: nil)
            }
        }
        for u in users where !asked.contains(u.key) {
            guard let first = since[u.key], now.timeIntervalSince(first) >= Self.promptAfter else { continue }
            // One prompt per call: apps already on the mic alongside it aren't asked about too.
            asked.formUnion(users.map { $0.key })
            // A card already up for this meeting covers it.
            guard PromptCard.shared.stage == .hidden else { break }
            lastPrompted = u.name
            Notifier.log("card: \(u.name) is using the microphone")
            PromptCard.shared.ask(event: Agenda.shared.current(at: now), app: u.name)
            break
        }
    }

    struct MicUser { let key: String; let name: String }

    /// Other apps using any microphone right now, from Core Audio's process list (macOS 14.2+).
    static func micUsers() -> [MicUser] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [MicUser] = []
        for id in ids {
            var running: UInt32 = 0
            var rsize = UInt32(MemoryLayout<UInt32>.size)
            var raddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &raddr, 0, nil, &rsize, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            var psize = UInt32(MemoryLayout<pid_t>.size)
            var paddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(id, &paddr, 0, nil, &psize, &pid)
            guard pid != me else { continue }
            var bundle: Unmanaged<CFString>?
            var bsize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var baddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(id, &baddr, 0, nil, &bsize, &bundle)
            let bundleID = bundle?.takeRetainedValue() as String? ?? ""
            if ignored.contains(bundleID) { continue }
            let owner = Self.owner(pid: pid, bundleID: bundleID)
            if owner.system { continue }
            let key = owner.id ?? (bundleID.isEmpty ? "pid\(pid)" : bundleID)
            if ignored.contains(key) { continue }
            let name = owner.name
            if !out.contains(where: { $0.key == key }) { out.append(MicUser(key: key, name: name)) }
        }
        return out
    }

    /// The app a person would recognise. Teams, Chrome and other browsers capture audio in a
    /// helper process inside their own bundle, so the outermost .app in the helper's path
    /// names the real app.
    static func owner(pid: pid_t, bundleID: String) -> (id: String?, name: String, system: Bool) {
        let running = NSRunningApplication(processIdentifier: pid)
        var path = running?.bundleURL?.path ?? running?.executableURL?.path
        if path == nil {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 { path = String(cString: buf) }
        }
        if let path, let r = path.range(of: ".app/") ?? path.range(of: ".app", options: .backwards), r.upperBound <= path.endIndex {
            let appPath = String(path[..<path.index(r.lowerBound, offsetBy: 4)])
            let bundle = Bundle(path: appPath)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? FileManager.default.displayName(atPath: appPath).replacingOccurrences(of: ".app", with: "")
            return (bundle?.bundleIdentifier, name, false)
        }
        let system = (path.map { $0.hasPrefix("/System/") || $0.hasPrefix("/usr/") } ?? false) || bundleID.hasPrefix("com.apple.")
        return (nil, running?.localizedName ?? "Another app", system)
    }
}

/// One delegate for all of Jotter's notifications: updates, and the meeting prompts with
/// their buttons.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let callEnded = "jotter-call-ended"
    static let update = "jotter-update"

    func install() {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        // A call prompt from before this launch no longer applies.
        c.getDeliveredNotifications { delivered in
            let stale = delivered.map { $0.request.identifier }.filter { $0.hasPrefix("jotter-call") }
            if !stale.isEmpty { c.removeDeliveredNotifications(withIdentifiers: stale) }
        }
        c.setNotificationCategories([
            UNNotificationCategory(identifier: Self.callEnded, actions: [
                UNNotificationAction(identifier: "stop", title: "Stop and write notes", options: []),
                UNNotificationAction(identifier: "dismiss", title: "Keep recording", options: []),
            ], intentIdentifiers: []),
        ])
    }

    /// A one-line record of each notification, for diagnosing "I never saw it".
    static func log(_ line: String) {
        let url = Store.recordings.deletingLastPathComponent().appendingPathComponent("notifications.log")
        let entry = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(entry.utf8)); try? h.close() }
        else { try? entry.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Removes a prompt from Notification Centre once it no longer applies.
    static func clear(_ id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }

    static func post(id: String, title: String, body: String, category: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { Notifier.log("\(granted ? "sent" : "not allowed"): \(title) | \(body)") }
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            c.categoryIdentifier = category
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let category = response.notification.request.content.categoryIdentifier
        let action = response.actionIdentifier
        await MainActor.run {
            let r = JotterApp.recorder
            switch (category, action) {
            case (Notifier.callEnded, "stop"), (Notifier.callEnded, UNNotificationDefaultActionIdentifier):
                if r.isRecording { r.stop() }
            case (Notifier.update, _) where action != UNNotificationDismissActionIdentifier:
                Updater.shared.install()
            default: break
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
