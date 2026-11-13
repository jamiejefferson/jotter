import AVFoundation
import AppKit
import Carbon.HIToolbox
import ServiceManagement

enum Kind: String { case meeting, note }

struct Saved: Equatable {
    let folder: URL
    let kind: Kind
    let seconds: Double
    var warning: String?
    var transcript: URL?
    var note: URL?
}

enum Store {
    static var recordings: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Jotter/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date)
    }

    static func iso(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return ISO8601DateFormatter().string(from: date)
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(lowered).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(48))
    }

    /// Compresses any `.caf` left by a crash and gives its folder an info file.
    static func recoverUnfinished() {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: recordings, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            let cafs = files.filter { $0.pathExtension == "caf" }
            guard !cafs.isEmpty else { continue }
            var tracks: [[String: Any]] = []
            for caf in cafs {
                if let r = try? TrackWriter.compress(caf) {
                    tracks.append(["name": caf.deletingPathExtension().lastPathComponent,
                                   "file": r.url.lastPathComponent, "seconds": r.seconds.rounded()])
                }
            }
            let info = folder.appendingPathComponent("info.json")
            if !fm.fileExists(atPath: info.path) {
                let body: [String: Any] = ["recovered": true, "note": "Recording was interrupted; saved on next launch.",
                                           "tracks": tracks]
                if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: info)
                }
            }
        }
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var kind: Kind?
    @Published private(set) var startedAt: Date?
    @Published var label = ""
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var callLevel: Float = 0
    @Published private(set) var callHeard = false
    @Published private(set) var message: String?
    @Published private(set) var micBlocked = false
    @Published private(set) var saving = false
    @Published private(set) var transcribing = false
    @Published private(set) var writingNotes = false
    /// True while the bar shows what happened after a meeting stopped (notes ready, or why not).
    @Published private(set) var showingResult = false
    private var resultTimer: Timer?
    /// Meetings shorter than this are taken as an accidental double tap and thrown away.
    static let accidentalSeconds = 5.0
    @Published private(set) var last: Saved?
    @Published private(set) var paused = false
    /// The vault project this recording belongs to, or "" to let the notes model decide.
    @Published var project = ""
    /// Vault projects, read when a recording starts.
    @Published private(set) var projects: [String] = []
    @Published var openAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                message = "Couldn't change Open at login: \(error.localizedDescription)"
            }
        }
    }

    private var mic: MicCapture?
    private var call: CallCapture?
    private var folder: URL?
    private var timer: Timer?
    private var hotKey: HotKey?
    private var meetingKey: HotKey?
    private var pauseKey: HotKey?
    /// Spans of the recording that were paused, in seconds from the start.
    private var pauses: [(from: Double, to: Double)] = []
    private var pausedAt: Date?
    private var hud: RecordingHUD?

    var isRecording: Bool { kind != nil }

    init() {
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            Task { @MainActor in self?.hotKeyPressed() }
        }
        meetingKey = HotKey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            Task { @MainActor in self?.meetingKeyPressed() }
        }
        pauseKey = HotKey(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | optionKey | cmdKey)) { [weak self] in
            Task { @MainActor in self?.togglePause() }
        }
        Task.detached(priority: .utility) { Store.recoverUnfinished() }
        NotificationCenter.default.addObserver(forName: .jotterToggleMeeting, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.toggleMeeting() }
        }
    }

    func hotKeyPressed() {
        if isRecording { stop() } else { start(.note) }
    }

    func meetingKeyPressed() {
        if isRecording { stop() } else { start(.meeting) }
    }

    /// Goes off the record without ending the recording, so one meeting stays one set of notes.
    /// Starts a meeting, or stops whatever is recording. Bound to a double tap of right Command.
    func toggleMeeting() {
        if isRecording { stop() } else { start(.meeting) }
    }

    func togglePause() {
        guard isRecording, let startedAt else { return }
        let writers = [mic?.writer, call?.writer].compactMap { $0 }
        if let pausedAt {
            pauses.append((pausedAt.timeIntervalSince(startedAt), Date().timeIntervalSince(startedAt)))
            self.pausedAt = nil
            writers.forEach { $0.paused = false }
            paused = false
        } else {
            pausedAt = Date()
            writers.forEach { $0.paused = true }
            paused = true
        }
    }

    func start(_ kind: Kind) {
        guard !isRecording, !saving else { return }
        message = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin(kind)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    if granted { self.begin(kind) } else { self.micBlocked = true }
                }
            }
        default:
            micBlocked = true
        }
    }

    private func begin(_ kind: Kind) {
        micBlocked = false
        let now = Date()
        let folder = Store.recordings.appendingPathComponent("\(Store.stamp(now))-\(kind.rawValue)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let mic = MicCapture()
            try mic.start(folder: folder)
            self.mic = mic
        } catch {
            message = "Couldn't start the microphone: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: folder)
            return
        }
        if kind == .meeting {
            let call = CallCapture()
            do {
                try call.start(folder: folder)
                self.call = call
            } catch {
                call.stop()
                message = "Recording your mic only. Call audio failed: \(error.localizedDescription)"
            }
        }
        self.folder = folder
        self.kind = kind
        startedAt = now
        elapsed = 0
        callHeard = false
        label = ""
        project = ""
        projects = Projects.list()
        pauses = []
        pausedAt = nil
        paused = false
        if hud == nil { hud = RecordingHUD(recorder: self) }
        showingResult = false
        resultTimer?.invalidate()
        hud?.show()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        micLevel = Self.meter(mic?.writer?.takePeak() ?? 0)
        callLevel = Self.meter(call?.writer?.takePeak() ?? 0)
        if call?.writer?.heardSound == true { callHeard = true }
    }

    /// Maps a peak sample to 0...1 on a 60 dB scale.
    private static func meter(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        return max(0, min(1, (20 * log10(peak) + 60) / 60))
    }

    func stop() {
        guard let kind, let folder, let startedAt else { return }
        if let pausedAt { pauses.append((pausedAt.timeIntervalSince(startedAt), Date().timeIntervalSince(startedAt))) }
        let pauses = self.pauses.map { ["from": $0.from.rounded(), "to": $0.to.rounded()] }
        let project = self.project
        pausedAt = nil
        paused = false
        // A meeting keeps the bar, which follows the notes through to "ready".
        let accidental = kind == .meeting && Date().timeIntervalSince(startedAt) < Self.accidentalSeconds
        if kind == .meeting && !accidental { showingResult = true } else { hud?.hide() }
        timer?.invalidate()
        timer = nil
        mic?.stop()
        call?.stop()
        let writers = [mic?.writer, call?.writer].compactMap { $0 }
        let micName = mic?.deviceName ?? ""
        let label = self.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let endedAt = Date()
        mic = nil
        call = nil
        self.kind = nil
        self.folder = nil
        self.startedAt = nil
        micLevel = 0
        callLevel = 0
        saving = true

        Task.detached(priority: .userInitiated) {
            var tracks: [[String: Any]] = []
            var problems: [String] = []
            for w in writers {
                let r = w.finish()
                var track: [String: Any] = [
                    "name": r.name, "sampleRate": r.sampleRate,
                    "seconds": (Double(r.frames) / r.sampleRate).rounded(),
                    "firstSampleAt": Store.iso(r.firstSampleAt), "heardSound": r.heardSound,
                ]
                if let e = r.error { track["writeError"] = e; problems.append("\(r.name): \(e)") }
                do {
                    let out = try TrackWriter.compress(r.caf)
                    track["file"] = out.url.lastPathComponent
                } catch {
                    track["file"] = r.caf.lastPathComponent
                    problems.append("\(r.name) kept uncompressed: \(error.localizedDescription)")
                }
                if r.name == "call" && !r.heardSound { problems.append("Call audio was silent.") }
                tracks.append(track)
            }
            if accidental {
                // An accidental double tap: keep nothing, and keep showing the previous meeting.
                try? FileManager.default.removeItem(at: folder)
                await MainActor.run { self.saving = false }
                return
            }
            let info: [String: Any] = [
                "app": "Jotter \(Updater.current)", "kind": kind.rawValue, "label": label,
                "startedAt": Store.iso(startedAt), "endedAt": Store.iso(endedAt),
                "seconds": endedAt.timeIntervalSince(startedAt).rounded(),
                "microphone": micName, "tracks": tracks,
                "callSource": kind == .meeting ? "All audio playing on this Mac" : NSNull(),
                "pauses": pauses, "project": project,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: folder.appendingPathComponent("info.json"))
            }
            var final = folder
            let slug = Store.slug(label)
            if !slug.isEmpty {
                let renamed = folder.deletingLastPathComponent()
                    .appendingPathComponent("\(folder.lastPathComponent)-\(slug)", isDirectory: true)
                if (try? FileManager.default.moveItem(at: folder, to: renamed)) != nil { final = renamed }
            }
            let saved = Saved(folder: final, kind: kind, seconds: endedAt.timeIntervalSince(startedAt),
                              warning: problems.isEmpty ? nil : problems.joined(separator: " "))
            await MainActor.run {
                self.saving = false
                self.last = saved
                self.transcribing = true
            }
            // Transcribe on the Mac with Apple's free on-device engine.
            var result = saved
            if #available(macOS 26.0, *) {
                do {
                    try await Transcribe.transcribe(folder: final, wanted: "en-GB")
                    result.transcript = final.appendingPathComponent("transcript.md")
                } catch {
                    result.warning = [saved.warning, "Transcription failed: \(error.localizedDescription)"]
                        .compactMap { $0 }.joined(separator: " ")
                }
            }
            let transcribed = result
            await MainActor.run {
                self.transcribing = false
                if self.last?.folder == transcribed.folder { self.last = transcribed }
                if kind == .meeting && transcribed.transcript != nil { self.writingNotes = true }
            }
            // Meetings get notes written and filed in the vault, unless almost nothing was said
            // (an accidental double tap, say), which would only clutter the vault.
            guard kind == .meeting, let transcriptURL = result.transcript else {
                await MainActor.run { self.finishResult() }
                return
            }
            let words = ((try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? "")
                .components(separatedBy: "\n").filter { $0.hasPrefix("**") }
                .joined(separator: " ").split(whereSeparator: \.isWhitespace).count
            if words < MeetingNotes.minimumWords {
                let shortFolder = final
                await MainActor.run {
                    self.writingNotes = false
                    if self.last?.folder == shortFolder { self.last?.warning = "Too short for notes, so none were written." }
                    self.finishResult()
                }
                return
            }
            do {
                result.note = try await MeetingNotes.generate(folder: final)
            } catch {
                result.warning = [result.warning, error.localizedDescription].compactMap { $0 }.joined(separator: " ")
            }
            let done = result
            await MainActor.run {
                self.writingNotes = false
                if self.last?.folder == done.folder { self.last = done }
                NotificationCenter.default.post(name: .jotterMeetingsChanged, object: nil)
                self.finishResult()
            }
        }
    }

    /// Leaves the result on the bar for two minutes, then tidies it away.
    private func finishResult() {
        guard showingResult else { return }
        resultTimer?.invalidate()
        resultTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissResult() }
        }
    }

    func dismissResult() {
        resultTimer?.invalidate()
        guard kind == nil else { return }
        showingResult = false
        hud?.hide()
    }

    func viewResult() {
        if let folder = last?.folder { MeetingsWindow.shared.show(meeting: folder) }
        dismissResult()
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func openRecordings() { NSWorkspace.shared.open(Store.recordings) }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func openMicSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func openAudioCaptureSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

extension Notification.Name {
    static let jotterToggleMeeting = Notification.Name("JotterToggleMeeting")
    static let jotterMeetingsChanged = Notification.Name("JotterMeetingsChanged")
}
