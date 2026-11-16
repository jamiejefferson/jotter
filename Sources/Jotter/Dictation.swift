import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import Speech
import SwiftUI

// Press-and-hold dictation. Hold right Command anywhere, speak, release, and the
// words land in the field that had focus when the key went down. Speech is
// recognised on this Mac by Apple's engine; nothing leaves the Mac.

// MARK: - Live microphone

/// Streams the built-in microphone to a callback while dictation is held.
/// Uses the built-in mic for the same reason MicCapture does: opening Bluetooth
/// earbuds' mic drops them into low-quality call mode.
final class MicStream: @unchecked Sendable {
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.eqtr.jotter.dictation-mic", qos: .userInteractive)

    func start(_ onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let id = AudioDevices.builtInInput() ?? AudioDevices.defaultInput() else {
            throw CaptureError(message: "No microphone is available.")
        }
        guard var asbd = AudioDevices.inputFormat(id),
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError(message: "Couldn't read the microphone's format.")
        }
        deviceID = id
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, id, queue) { _, input, _, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            onBuffer(buf)
        }
        guard status == noErr else { throw CaptureError(message: "Couldn't attach to the microphone (\(status)).") }
        status = AudioDeviceStart(id, procID)
        guard status == noErr else { throw CaptureError(message: "Couldn't start the microphone (\(status)).") }
    }

    func stop() {
        if let procID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
    }
}

// MARK: - Recognition

/// One held press: audio goes in as it arrives, and `finish()` returns the text.
@available(macOS 26.0, *)
final class DictationSession: @unchecked Sendable {
    /// Locale and audio format, worked out once at launch so a press starts at once.
    struct Setup: @unchecked Sendable {
        let locale: Locale
        let format: AVAudioFormat
    }

    static func prepare(wanted: String = "en-GB") async throws -> Setup {
        let supported = await SpeechTranscriber.supportedLocales
        let candidates = [Locale(identifier: wanted), Locale(identifier: "en-GB"), Locale(identifier: "en-US")]
        guard let locale = candidates.first(where: { c in supported.contains { $0.identifier(.bcp47) == c.identifier(.bcp47) } })
        else { throw CaptureError(message: "No supported English locale for dictation.") }
        let module = makeModule(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw CaptureError(message: "Apple's speech engine offered no audio format.")
        }
        return Setup(locale: locale, format: format)
    }

    // SpeechTranscriber punctuates and capitalises on its own. Apple's DictationTranscriber
    // returned no text at all in testing on macOS 27.2, so it isn't used.
    private static func makeModule(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.fastResults], attributeOptions: [])
    }

    private let setup: Setup
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let stream: AsyncStream<AnalyzerInput>
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var running: Task<String, Error>?

    init(_ setup: Setup) {
        self.setup = setup
        (stream, input) = AsyncStream<AnalyzerInput>.makeStream()
        let module = Self.makeModule(setup.locale)
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let stream = self.stream
        let format = setup.format
        running = Task {
            let collect = Task { () -> String in
                var parts: [String] = []
                for try await r in module.results where r.isFinal { parts.append(String(r.text.characters)) }
                return parts.joined()
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: stream)
            // Waits until the input stream ends, then settles the last words.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            return try await collect.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Converts a buffer to the engine's format and queues it. Safe to call on the audio thread.
    func feed(_ buf: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        if buf.format == setup.format {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: buf.frameLength) else { return }
            copy.frameLength = buf.frameLength
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buf.audioBufferList))
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (s, d) in zip(src, dst) { memcpy(d.mData, s.mData, Int(s.mDataByteSize)) }
            input.yield(AnalyzerInput(buffer: copy))
            return
        }
        if converter == nil || converter?.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: setup.format)
        }
        guard let converter else { return }
        let ratio = setup.format.sampleRate / buf.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: setup.format, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buf
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    /// Ends the audio and returns the recognised text.
    func finish() async throws -> String {
        input.finish()
        return try await running?.value ?? ""
    }

    func cancel() {
        input.finish()
        running?.cancel()
    }
}

// MARK: - Hold key, insertion and state

@MainActor
final class Dictation: ObservableObject {
    enum State { case off, ready, listening, finishing }

    @Published private(set) var state: State = .off
    @Published private(set) var lastText = ""
    @Published private(set) var lastDelay: Double?
    @Published private(set) var message: String?
    @Published private(set) var trusted = AXIsProcessTrusted()
    @Published var tidying: Tidying = Tidying(rawValue: UserDefaults.standard.string(forKey: "dictationTidying") ?? "") ?? .tidy {
        didSet { UserDefaults.standard.set(tidying.rawValue, forKey: "dictationTidying") }
    }
    @Published var keepLog: Bool = UserDefaults.standard.object(forKey: "dictationLog") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepLog, forKey: "dictationLog") }
    }

    /// The key held to dictate and double-tapped for a meeting, chosen in the panel.
    @Published var holdKey: HoldKey = .current {
        didSet { UserDefaults.standard.set(holdKey.rawValue, forKey: HoldKey.defaultsKey) }
    }
    /// The mic waits this long after the press, so a ⌘ shortcut (⌘Tab, ⌘C) usually never
    /// wakes it. Speech rarely starts this soon after pressing.
    private static let micDelay = 0.12
    /// Presses shorter than this are taps, not dictation, and are ignored.
    private static let minimumHold = 0.3
    /// Two taps closer than this start or stop a meeting recording.
    private static let doubleTapGap = 0.4
    private var lastTapAt: Date?
    private var swallowRelease = false

    private var setupBox: Any?
    private var session: Any?
    private let mic = MicStream()
    private var monitors: [Any] = []
    private var pressedAt: Date?
    private var targetApp: NSRunningApplication?
    private var spoiled = false
    /// True when Shift is held with right Command: the words are an edit instruction, not new text.
    private var correcting = false
    /// The last text Jotter pasted, so a spoken correction can find and replace it.
    private var lastInsert: (text: String, pid: pid_t, at: Date)?
    /// False once a key or click happens after the paste, since the caret may have moved.
    private var insertFresh = false
    /// What Jotter pasted in the last day, to check a mishearing came from dictation before learning it.
    private var recentDictations: [String] = []
    private let hud = DictationHUD()
    private var trustTimer: Timer?
    /// When the key monitors last delivered any event, and how many since the last heartbeat.
    /// The watchdog compares this with the Mac's own record of key presses to notice when
    /// macOS has stopped sending Jotter events, as happened on 2026-11-16.
    private var lastEventAt = Date()
    private var eventsSinceBeat = 0
    private var lastBeat = Date()
    private var lastReinstall = Date.distantPast
    private var watchdog: Timer?

    init() {
        guard #available(macOS 26.0, *) else {
            message = "Dictation needs macOS 26 or later."
            return
        }
        installMonitors()
        Task {
            do {
                setupBox = try await DictationSession.prepare()
                state = .ready
            } catch {
                message = "Dictation couldn't start: \(error.localizedDescription)"
            }
        }
        // Ask once at launch: macOS shows its own prompt and adds Jotter to the Accessibility list.
        if !trusted { askForAccessibility() }
        KeyLog.write("launch: Jotter \(Updater.current), accessibility=\(trusted), key=\(holdKey.rawValue)")
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.checkMonitors() }
        }
    }

    /// Runs every 5 s. If the Mac saw a key or modifier press in the last few seconds but
    /// Jotter's monitors have heard nothing for much longer, macOS has stopped delivering
    /// events to Jotter: log it and install the monitors again. Also clears a press that
    /// never got its release, which would make every later press be ignored.
    private func checkMonitors() {
        let now = Date()
        let sinceKey = min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
                           CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .flagsChanged))
        let heardAgo = now.timeIntervalSince(lastEventAt)
        if sinceKey < 5, heardAgo > sinceKey + 20, now.timeIntervalSince(lastReinstall) > 60 {
            lastReinstall = now
            KeyLog.write("deaf: the Mac had a key press \(Int(sinceKey)) s ago but Jotter last heard one \(Int(heardAgo)) s ago; accessibility=\(AXIsProcessTrusted()). Reinstalling the key monitors.")
            installMonitors()
        }
        if let pressedAt, now.timeIntervalSince(pressedAt) > 120,
           CGEventSource.flagsState(.combinedSessionState).rawValue & UInt64(holdKey.flag) == 0 {
            KeyLog.write("stuck: a press from \(Int(now.timeIntervalSince(pressedAt))) s ago never got its release; clearing it")
            self.pressedAt = nil
            mic.stop()
            if #available(macOS 26.0, *) { (session as? DictationSession)?.cancel() }
            session = nil
            state = .ready
            hud.hide()
        }
        if now.timeIntervalSince(lastBeat) >= 1800 {
            KeyLog.write("heartbeat: \(eventsSinceBeat) events in \(Int(now.timeIntervalSince(lastBeat) / 60)) min, accessibility=\(AXIsProcessTrusted()), state=\(state), monitors=\(monitors.count)")
            eventsSinceBeat = 0
            lastBeat = now
        }
    }

    func openTidyingInstructions() {
        _ = Cleanup.extraInstructions()
        NSWorkspace.shared.open(Cleanup.instructionsFile)
    }

    func openVocabulary() {
        _ = Vocabulary.rules()
        NSWorkspace.shared.open(Vocabulary.file)
    }

    func askForAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
        watchTrust()
    }

    /// Accessibility is granted in System Settings; check every second until it arrives,
    /// then re-install the key monitors, which only start receiving events once trusted.
    private func watchTrust() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                if AXIsProcessTrusted() {
                    self.trusted = true
                    self.installMonitors()
                    t.invalidate()
                }
            }
        }
    }

    private func installMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        let handler: (NSEvent) -> Void = { [weak self] e in
            Task { @MainActor in self?.handle(e) }
        }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in handler(e); return e }) { monitors.append(l) }
        KeyLog.write("monitors installed: \(monitors.count) of 2, accessibility=\(AXIsProcessTrusted())")
    }

    private func handle(_ e: NSEvent) {
        lastEventAt = Date()
        eventsSinceBeat += 1
        switch e.type {
        case .flagsChanged where e.keyCode == holdKey.keyCode:
            if e.modifierFlags.rawValue & holdKey.flag != 0 {
                if let lastTapAt, Date().timeIntervalSince(lastTapAt) < Self.doubleTapGap, !e.modifierFlags.contains(.shift) {
                    // Second tap: start or stop a meeting, and don't dictate.
                    KeyLog.write("double-tap: toggling the meeting recording")
                    self.lastTapAt = nil
                    swallowRelease = true
                    NotificationCenter.default.post(name: .jotterToggleMeeting, object: nil)
                    return
                }
                KeyLog.write("key down\(e.modifierFlags.contains(.shift) ? " with shift" : "") in \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"), state=\(state)")
                press(correct: e.modifierFlags.contains(.shift))
            } else {
                KeyLog.write("key up")
                if swallowRelease { swallowRelease = false; return }
                release()
            }
        case .flagsChanged where e.keyCode == 56 || e.keyCode == 60:
            // Shift with right Command turns the press into a correction, whichever goes down first.
            if pressedAt != nil, e.modifierFlags.contains(.shift) { switchToCorrecting() }
        case .leftMouseDown:
            insertFresh = false
            if pressedAt != nil { spoil() }   // ⌘-click
        case .flagsChanged, .keyDown:
            insertFresh = false
            // Another key while holding means right Command is part of a shortcut.
            if pressedAt != nil { spoil() }
        default: break
        }
    }

    private func switchToCorrecting() {
        guard !correcting else { return }
        correcting = true
        hud.show("Say the change…")
    }

    /// The press is a shortcut: drop the mic and the pill straight away.
    private func spoil() {
        KeyLog.write("spoiled: another key or a click came while holding, so it's a shortcut")
        spoiled = true
        mic.stop()
        if #available(macOS 26.0, *) { (session as? DictationSession)?.cancel() }
        session = nil
        state = .ready
        hud.hide()
    }

    private func press(correct: Bool = false) {
        guard #available(macOS 26.0, *) else { return }
        if let pressedAt {
            KeyLog.write("press ignored: an earlier press from \(String(format: "%.1f", Date().timeIntervalSince(pressedAt))) s ago is still open")
            return
        }
        let at = Date()
        pressedAt = at
        spoiled = false
        correcting = correct
        targetApp = NSWorkspace.shared.frontmostApplication
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.micDelay) { [weak self] in
            guard let self, self.pressedAt == at, !self.spoiled else { return }
            self.listen()
        }
    }

    private func listen() {
        guard #available(macOS 26.0, *), let setup = setupBox as? DictationSession.Setup else {
            KeyLog.write("not listening: the speech engine isn't ready (state=\(state))")
            return
        }
        let s = DictationSession(setup)
        session = s
        do {
            try mic.start { buf in s.feed(buf) }
            KeyLog.write("listening")
        } catch {
            KeyLog.write("mic failed: \(error.localizedDescription)")
            message = error.localizedDescription
            s.cancel(); session = nil; pressedAt = nil
            return
        }
        state = .listening
        // Wait a moment before showing the pill, so a tap (or a double tap) doesn't flash it.
        let shownFor = pressedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) { [weak self] in
            guard let self, self.pressedAt == shownFor, self.state == .listening else { return }
            self.hud.show(self.correcting ? "Say the change…" : "Listening…")
        }
    }

    private func release() {
        guard #available(macOS 26.0, *), let pressedAt else { return }
        let releasedAt = Date()
        let held = releasedAt.timeIntervalSince(pressedAt)
        self.pressedAt = nil
        let session = self.session as? DictationSession
        self.session = nil
        mic.stop()
        KeyLog.write(String(format: "released after %.2f s%@", held, spoiled ? " (spoiled)" : session == nil ? " (no session)" : ""))
        guard let s = session, !spoiled, held >= Self.minimumHold else {
            if !spoiled && !correcting && held < Self.minimumHold { lastTapAt = releasedAt }
            session?.cancel()
            state = .ready
            hud.hide()
            return
        }
        state = .finishing
        if correcting {
            hud.show("Correcting…")
            Task {
                do { try await correct(heard: Vocabulary.apply(try await s.finish()), releasedAt: releasedAt) }
                catch { message = "Correction failed: \(error.localizedDescription)" }
                state = .ready
                hud.hide()
            }
            return
        }
        hud.show("Writing…")
        let target = targetApp
        Task {
            do {
                let heard = Vocabulary.apply(try await s.finish())
                let recognised = Date().timeIntervalSince(releasedAt)
                var text = heard
                var note: String?
                switch tidying {
                case .off: break
                case .light: text = Cleanup.light(heard)
                case .tidy where !heard.isEmpty:
                    hud.show("Tidying…")
                    do { text = try await Cleanup.tidy(heard) } catch {
                        text = Cleanup.light(heard)
                        note = error.localizedDescription
                    }
                case .tidy: break
                }
                let delay = Date().timeIntervalSince(releasedAt)
                deliver(text, heard: heard, to: target, held: held, recognised: recognised, delay: delay)
                if let note { message = note }
            } catch {
                message = "Dictation failed: \(error.localizedDescription)"
            }
            state = .ready
            hud.hide()
        }
    }

    /// Applies a spoken edit to the selected text or, with nothing selected, to the last dictation.
    private func correct(heard instruction: String, releasedAt: Date) async throws {
        guard !instruction.isEmpty else { message = "Didn't catch the change."; return }
        guard let target = Editing.findTarget(last: lastInsert, fresh: insertFresh) else {
            message = "Nothing to correct. Select the text first, or correct straight after dictating."
            return
        }
        let result = try await Cleanup.correct(target.text, instruction: instruction)
        let revised = result.text
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(revised, forType: .string)
            message = "You switched apps, so the corrected text is on the clipboard."
            return
        }
        await Editing.replace(target, with: revised)
        lastInsert = revised.isEmpty ? nil : (revised, target.pid, Date())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.insertFresh = !revised.isEmpty }
        lastText = revised.isEmpty ? "(deleted)" : revised
        lastDelay = Date().timeIntervalSince(releasedAt)
        message = nil
        // Learn only when JJ said the right word in the instruction, and only mishearings of words Jotter
        // itself wrote recently. A broad edit ("more formal") or an edit to typed text teaches nothing.
        let learned = result.misheard.filter { pair in
            instruction.range(of: pair.meant, options: .caseInsensitive) != nil
                && recentDictations.contains { $0.range(of: pair.heard, options: .caseInsensitive) != nil }
                && Vocabulary.learn(heard: pair.heard, meant: pair.meant)
        }
        if !learned.isEmpty {
            message = "Learned: " + learned.map { "\u{201C}\($0.heard)\u{201D} → \($0.meant)" }.joined(separator: ", ") + ". It's in your name fixes."
        }
        if keepLog {
            DictationLog.append(["kind": "correction", "instruction": instruction, "before": target.text, "text": revised,
                                 "learned": learned.map { "\($0.heard) => \($0.meant)" },
                                 "target": target.how.rawValue, "delay": round(Date().timeIntervalSince(releasedAt) * 1000) / 1000,
                                 "app": NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier ?? ""])
        }
    }

    private func deliver(_ text: String, heard: String, to target: NSRunningApplication?, held: Double, recognised: Double, delay: Double) {
        lastDelay = delay
        guard !text.isEmpty else {
            message = "Didn't catch any words."
            return
        }
        lastText = text
        message = nil
        let sameApp = target?.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier
        if sameApp && AXIsProcessTrusted() {
            Paste.insert(text)
            recentDictations = Array((recentDictations + [heard, text]).suffix(100))
            if let pid = target?.processIdentifier {
                lastInsert = (text, pid, Date())
                // The paste's own Cmd+V reaches the key monitor a moment later; mark fresh after it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.insertFresh = true }
            }
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            message = sameApp ? "Text is on the clipboard. Allow Jotter in Accessibility to paste it for you."
                              : "You switched apps, so the text is on the clipboard."
        }
        if keepLog {
            DictationLog.append(["text": text, "heard": heard, "tidying": tidying.rawValue, "held": round(held * 100) / 100,
                                 "recognised": round(recognised * 1000) / 1000, "delay": round(delay * 1000) / 1000,
                                 "app": target?.bundleIdentifier ?? ""])
        }
    }
}

// MARK: - Paste

enum Paste {
    /// Puts the text on the clipboard, presses Cmd+V, then puts back whatever was there.
    static func insert(_ text: String) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCount = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9 /* V */, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Leave the clipboard alone if something else changed it in the meantime.
            guard pb.changeCount == changeCount else { return }
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}

// MARK: - Log

/// A dated log of what was dictated, for the Phase 2 accuracy check. Stays on this Mac.
enum DictationLog {
    static var folder: URL { Store.recordings.deletingLastPathComponent().appendingPathComponent("Dictation", isDirectory: true) }

    static func append(_ fields: [String: Any]) {
        let now = Date()
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        var row = fields
        row["at"] = ISO8601DateFormatter().string(from: now)
        guard let data = try? JSONSerialization.data(withJSONObject: row) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(day).jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data + Data("\n".utf8)); try? h.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: url)
        }
    }
}

// MARK: - Key log

/// What the dictation key did, to find where a press goes missing. It records the hold key,
/// Jotter's decisions and event counts, never which other keys were typed. Stays on this Mac
/// at `~/Library/Application Support/Jotter/keys.log` and keeps about the last 400 KB.
enum KeyLog {
    static var file: URL { Store.recordings.deletingLastPathComponent().appendingPathComponent("keys.log") }

    static func write(_ line: String) {
        let row = Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8)
        let url = file
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil, size > 400_000,
           let data = try? Data(contentsOf: url) {
            try? data.suffix(200_000).write(to: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(row); try? h.close()
        } else {
            try? row.write(to: url)
        }
    }
}

// MARK: - On-screen cue

/// A small pill at the bottom of the screen while dictation listens, because the
/// menu-bar icon can sit in the hidden part of the menu bar. It never takes focus.
@MainActor
final class DictationHUD {
    private var panel: NSPanel?
    private let model = Model()

    final class Model: ObservableObject { @Published var text = "" }

    struct Pill: View {
        @ObservedObject var model: Model
        var body: some View {
            HStack(spacing: 8) {
                Dot()
                Text(model.text).font(Theme.font(13, .semibold)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.subtleLine, lineWidth: 1))
            .fixedSize()
            .environment(\.colorScheme, .dark)
        }
    }

    func show(_ text: String) {
        model.text = text
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 36),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.level = .statusBar
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.contentView = NSHostingView(rootView: Pill(model: model))
            p.appearance = Theme.appearance
            panel = p
        }
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 160, height: 36)
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 48, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

// MARK: - Vocabulary

/// Fixes names Apple's engine mishears, such as "key bus" for KeyBus. The list is a
/// plain text file JJ can edit: one name per line, then a colon and the misheard forms.
///   KeyBus: key bus, keybus
enum Vocabulary {
    static var file: URL { Store.recordings.deletingLastPathComponent().appendingPathComponent("vocabulary.txt") }

    static let starter = """
    # Jotter dictation vocabulary. One line per name: the right spelling, a colon,
    # then the misheard forms separated by commas. Matching ignores case and only
    # replaces whole words. Lines starting with # are ignored. Changes apply on the next press.
    KeyBus: key bus, key buss, keybus, key bass
    Canon: cannon
    Supabase: superbase, super base, supa base
    README: read me
    Jotter: jotter, jotta
    Indy: indie
    SwiftUI: swift ui, swift you i
    Equator: equator
    Eqtr: eq tr
    Optimizely: optimisely, optimizely
    IDEalize: ideal eyes, ideal ice, idealise, idealize, ide alize
    Obsidian: obsidian
    Meeting Desk: meeting desk
    """

    /// Rules in the order they apply: longer misheard forms first, so "key bus" wins over "bus".
    static func rules() -> [(NSRegularExpression, String)] {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? starter.write(to: file, atomically: true, encoding: .utf8)
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var pairs: [(String, String)] = []
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let colon = l.firstIndex(of: ":") else { continue }
            let right = l[..<colon].trimmingCharacters(in: .whitespaces)
            guard !right.isEmpty else { continue }
            for wrong in l[l.index(after: colon)...].split(separator: ",") {
                let w = wrong.trimmingCharacters(in: .whitespaces)
                if !w.isEmpty { pairs.append((w, right)) }
            }
        }
        pairs.sort { $0.0.count > $1.0.count }
        return pairs.compactMap { wrong, right in
            let words = wrong.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = "(?<![\\w'])" + words.joined(separator: "[\\s-]+") + "(?![\\w'])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (re, NSRegularExpression.escapedTemplate(for: right))
        }
    }

    /// Adds a mishearing found by a spoken correction. Skips short single words ("for" heard for
    /// "four" would break ordinary text) and anything already covered. Returns true when added.
    static func learn(heard: String, meant: String) -> Bool {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines), m = meant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !m.isEmpty, h != m, h.count <= 40, m.count <= 40,
              h.split(separator: " ").count <= 4, m.split(separator: " ").count <= 4,
              !h.contains(":"), !h.contains(","), !m.contains(":"), !m.contains(",") else { return false }
        if !h.contains(" ") && h.count < 5 { return false }
        if apply(h) == m { return false }
        _ = rules()  // makes sure the file exists
        guard var lines = (try? String(contentsOf: file, encoding: .utf8))?.components(separatedBy: "\n") else { return false }
        let header = "# Learned from spoken corrections. Delete a line to forget it."
        if let i = lines.firstIndex(where: { l in
            !l.hasPrefix("#") && l.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } == m }) {
            lines[i] += ", " + h.lowercased()
        } else {
            if !lines.contains(header) {
                while lines.last?.isEmpty == true { lines.removeLast() }
                lines += ["", header]
            }
            lines.append("\(m): \(h.lowercased())")
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
        return (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil
    }

    static func apply(_ text: String) -> String {
        var out = text
        for (re, template) in rules() {
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        return out
    }
}

// MARK: - Tidying

/// How much Jotter tidies dictated words before pasting them.
/// Keys that can be held to dictate and double-tapped for a meeting. Each is a modifier
/// on its own, so holding it types nothing. Right ⌘ is the default: right ⌥ clashes with
/// Claude's double-tap-Option quick entry, and Fn with Wispr and macOS dictation.
enum HoldKey: String, CaseIterable, Identifiable {
    case rightCommand, rightOption, rightControl, fn
    static let defaultsKey = "holdKey"
    static var current: HoldKey { HoldKey(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .rightCommand }

    var id: String { rawValue }
    var keyCode: UInt16 { switch self { case .rightCommand: 54; case .rightOption: 61; case .rightControl: 62; case .fn: 63 } }
    /// The device-specific flag for this exact key, so the other side's key held down doesn't hide a release.
    var flag: UInt { switch self { case .rightCommand: 0x10; case .rightOption: 0x40; case .rightControl: 0x2000; case .fn: 0x800000 } }
    /// The full flags a key-down carries, for the self-test that posts taps.
    var eventFlags: UInt64 {
        switch self {
        case .rightCommand: CGEventFlags.maskCommand.rawValue | 0x10
        case .rightOption: CGEventFlags.maskAlternate.rawValue | 0x40
        case .rightControl: CGEventFlags.maskControl.rawValue | 0x2000
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }
    var symbol: String { switch self { case .rightCommand: "right ⌘"; case .rightOption: "right ⌥"; case .rightControl: "right ⌃"; case .fn: "Fn" } }
    var label: String { switch self { case .rightCommand: "Right ⌘"; case .rightOption: "Right ⌥"; case .rightControl: "Right ⌃"; case .fn: "Fn" } }
    var note: String? {
        switch self {
        case .rightCommand: nil
        case .rightOption: "Claude's app also opens on a double tap of ⌥. Change its shortcut in Claude's settings."
        case .rightControl: "Most Mac laptops have no right ⌃; use this with an external keyboard."
        case .fn: "macOS uses Fn for its own dictation and emoji. Set \u{201C}Press 🌐 key to\u{201D} to Do Nothing in Keyboard settings."
        }
    }
}

enum Tidying: String, CaseIterable, Identifiable {
    case off, light, tidy
    var id: String { rawValue }
    var label: String { ["off": "Off", "light": "Light", "tidy": "Tidy"][rawValue]! }
    var detail: String {
        switch self {
        case .off: return "Pastes exactly what you said."
        case .light: return "Removes ums, ers and repeated words on this Mac. Instant."
        case .tidy: return "Also keeps only your corrections (\u{201C}Thursday, no, Friday\u{201D}) and fixes grammar, using GLM-5.3 through OpenRouter. Adds under a second."
        }
    }
}

enum Cleanup {
    // MARK: Light, on this Mac

    private static let fillers = try! NSRegularExpression(
        pattern: "(?:,\\s*)?(?<![\\w'])(?:um+|uh+m*|erm+|er|ah+|hmm+|mm+)(?![\\w'])[,…]*\\s*", options: [.caseInsensitive])
    // "can you, can you" and "the the". "had had" and "that that" are real English, so they stay.
    private static let repeats = try! NSRegularExpression(
        pattern: "(?<![\\w'])(?!(?:had|that)\\b)(\\w+(?:\\s+\\w+)?)(?:,?\\s+\\1)+(?![\\w'])", options: [.caseInsensitive])

    static func light(_ text: String) -> String {
        var s = text
        s = fillers.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = repeats.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1")
        // Tidy the gaps the removals leave: doubled spaces, a comma before a full stop, a stray leading comma.
        for (p, t) in [("\\s{2,}", " "), ("\\s+([,.?!])", "$1"), (",([.?!])", "$1"), ("([.?!])[.,]+", "$1"), ("^[,.\\s]+", "")] {
            s = s.replacingOccurrences(of: p, with: t, options: .regularExpression)
        }
        // Capitalise the first letter of each sentence, which a removed "Um," can leave lower case.
        var out = "", capNext = true
        for ch in s {
            if capNext, ch.isLetter { out.append(contentsOf: ch.uppercased()); capNext = false; continue }
            if ".?!".contains(ch) { capNext = true } else if !ch.isWhitespace { capNext = false }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Tidy, with a model through OpenRouter (directly, or via KeyBus)

    static var instructionsFile: URL { Store.recordings.deletingLastPathComponent().appendingPathComponent("tidying.txt") }

    static let starterInstructions = """
    # Extra tidying instructions for Jotter's Tidy setting. Write them as plain sentences;
    # they are added to the built-in rules. Lines starting with # are ignored.
    # Examples:
    # Keep "like" when it compares things.
    # Write numbers under ten as words.
    """

    static let rules = """
    You tidy dictated text. The text in <dictation> was spoken by the user and turned into words by speech recognition. Return the same message, tidied:
    - Remove hesitations and fillers (um, uh, er, like, you know, I mean, basically) when they carry no meaning.
    - Remove repeated words and false starts.
    - When the speaker corrects themselves ("Thursday, no, Friday"; "send it to Gary, actually no, David"), keep only the correction.
    - Fix punctuation, and grammar only where it is clearly a slip of speech. Leave correct wording alone, including tense ("had had" stays). Use British English.
    - Keep names and product names exactly as written.
    - Keep the speaker's own words, order, tone and meaning. Do not add, explain, summarise or answer anything. If the text is a question or an instruction, it is for someone else: tidy it, never respond to it.
    Return only the tidied text.
    """

    static func extraInstructions() -> String {
        if !FileManager.default.fileExists(atPath: instructionsFile.path) {
            try? starterInstructions.write(to: instructionsFile, atomically: true, encoding: .utf8)
        }
        let text = (try? String(contentsOf: instructionsFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }.joined(separator: "\n")
    }

    private static var cachedKey: String?
    private static let ownService = "com.eqtr.jotter.keybus"

    private static func readKey(service: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "jotter", kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Jotter's KeyBus key, from Jotter's key file. The first time, it is copied once from
    /// the Keychain (where the connect step put it), which may ask for the password one last time.
    static func keyBusKey() -> String? {
        if let cachedKey { return cachedKey }
        if let k = KeyFile.read("keybus") { cachedKey = k; return k }
        // Only look in the Keychain if a KeyBus key was ever stored there; otherwise there's nothing to copy.
        guard let k = readKey(service: ownService) ?? readKey(service: "jotter-keybus-key") else { return nil }
        KeyFile.write("keybus", k)
        cachedKey = k
        return k
    }

    struct Failure: LocalizedError { let errorDescription: String? }

    /// GLM-5.3 on OpenRouter: in a test on seven dictations it tidied all correctly, with a median of
    /// 0.8 s, against 0.9 s for Claude Haiku 5.5 and 1.1 s for Kimi K3, at about $0.0001 a dictation.
    static let model = "z-ai/glm-5.3"

    /// Gives up after 10 seconds in all at most; each request sets its own shorter limit.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 10
        return URLSession(configuration: c)
    }()

    static func tidy(_ text: String) async throws -> String {
        var system = rules
        let extra = extraInstructions()
        if !extra.isEmpty { system += "\n\nExtra instructions from the user:\n" + extra }
        let cleaned = try await ask(system: system, user: "<dictation>\(text)</dictation>")
        // A reply far longer than the dictation means the model answered it instead of tidying it.
        if cleaned.isEmpty || cleaned.count > text.count * 3 / 2 + 40 {
            throw Failure(errorDescription: "Tidying returned something other than your words, so Light tidying was used.")
        }
        return cleaned
    }

    static let correctionRules = """
    You edit text by voice. <text> holds text the user wrote. <instruction> is what the user then said to change it, turned into words by speech recognition, so it may contain misheard words; work out what they meant.
    Apply the instruction to the text and return the whole revised text.
    - Change only what the instruction asks. Keep everything else exactly as it is, including wording, punctuation and line breaks.
    - Instructions can be specific ("change Thursday to Friday", "spell Kayleigh with a K", "drop the last sentence") or broad ("make it more polite", "shorter", "turn it into bullet points").
    - If the instruction says to delete, scratch or remove all of it, the revised text is <empty/>.
    - Use British English.
    Then list any words the speech recognition got wrong that this instruction fixes: where a word or phrase in the text is a mishearing of what the user meant, because they sound alike or the user says it was spelled or heard wrong ("Kaylee" for "Kayleigh", "ideal eyes" for "IDEalize"). Do not list content changes such as a different day, number, name of a different person, or a wording choice.
    Reply in exactly this form, with nothing else:
    <revised>the whole revised text</revised>
    <misheard heard="what the text had" meant="what the user meant"/>   (one line per mishearing; none if there are none)
    """

    struct Correction {
        let text: String
        let misheard: [(heard: String, meant: String)]
    }

    static func correct(_ text: String, instruction: String) async throws -> Correction {
        let out = try await ask(system: correctionRules,
                                user: "<text>\(text)</text>\n<instruction>\(instruction)</instruction>", timeout: 10)
        var revised = out
        if let a = out.range(of: "<revised>"), let b = out.range(of: "</revised>", range: a.upperBound..<out.endIndex) {
            revised = String(out[a.upperBound..<b.lowerBound])
        } else {
            revised = out.replacingOccurrences(of: "<misheard[^>]*/>", with: "", options: .regularExpression)
        }
        revised = revised.trimmingCharacters(in: .whitespacesAndNewlines)
        if revised.contains("<empty/>") { revised = "" }
        let re = try! NSRegularExpression(pattern: "<misheard\\s+heard=\"([^\"]+)\"\\s+meant=\"([^\"]+)\"\\s*/>")
        let pairs = re.matches(in: out, range: NSRange(out.startIndex..., in: out)).compactMap { m -> (String, String)? in
            guard let h = Range(m.range(at: 1), in: out), let w = Range(m.range(at: 2), in: out) else { return nil }
            return (String(out[h]).trimmingCharacters(in: .whitespaces), String(out[w]).trimmingCharacters(in: .whitespaces))
        }
        return Correction(text: revised, misheard: pairs)
    }

    static func ask(system: String, user: String, timeout: TimeInterval = 5) async throws -> String {
        var req = try ModelAccess.request(timeout: timeout)
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 1024, "temperature": 0,
            // GLM-5.3 can't switch reasoning off; minimal keeps it under a second.
            "reasoning": ["effort": "minimal"],
            // Only providers that neither store nor train on what JJ dictates.
            "provider": ["data_collection": "deny"],
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ])
        let (data, resp) = try await session.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let choices = json?["choices"] as? [[String: Any]],
              let out = (choices.first?["message"] as? [String: Any])?["content"] as? String else {
            let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw Failure(errorDescription: "The model call failed: \(msg)")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Finding and replacing the text to correct

enum Editing {
    enum How: String { case selection, lastDictation, lastDictationByKeys }

    struct Target {
        let text: String
        let pid: pid_t
        let how: How
    }

    private static func focused() -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func range(_ el: AXUIElement) -> CFRange? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    private static func select(_ el: AXUIElement, _ r: CFRange) -> Bool {
        var r = r
        guard let v = AXValueCreate(.cfRange, &r) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    /// Selected text wins. Otherwise the last dictation, found through Accessibility where the app
    /// supports it, or by deleting back over it with Backspace if nothing has been typed or clicked since.
    static func findTarget(last: (text: String, pid: pid_t, at: Date)?, fresh: Bool) -> Target? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let el = focused()
        if let el, let sel = string(el, kAXSelectedTextAttribute as String), !sel.isEmpty {
            return Target(text: sel, pid: pid, how: .selection)
        }
        guard let last, last.pid == pid, Date().timeIntervalSince(last.at) < 15 * 60 else { return nil }
        if let el, let value = string(el, kAXValueAttribute as String), let r = range(el), r.length == 0 {
            let ns = value as NSString
            let n = (last.text as NSString).length
            if r.location >= n, r.location <= ns.length,
               ns.substring(with: NSRange(location: r.location - n, length: n)) == last.text,
               select(el, CFRange(location: r.location - n, length: n)) {
                return Target(text: last.text, pid: pid, how: .lastDictation)
            }
        }
        return fresh ? Target(text: last.text, pid: pid, how: .lastDictationByKeys) : nil
    }

    /// Replaces the target in place. An empty replacement deletes it.
    static func replace(_ t: Target, with text: String) async {
        let src = CGEventSource(stateID: .hidSystemState)
        func post(_ code: CGKeyCode, down: Bool, _ flags: CGEventFlags = []) {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        if t.how == .lastDictationByKeys {
            // The caret still sits at the end of the last paste, so Backspace removes exactly it.
            // This works in terminals too, which have no text selection (Shift+Left only moves the
            // cursor there). Paced, because browser-based apps drop keys that arrive in a burst.
            for _ in 0..<t.text.count {
                post(51 /* Delete */, down: true)
                post(51, down: false)
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            if !text.isEmpty { Paste.insert(text) }
            return
        }
        // A selection: pasting replaces it, and Delete removes it.
        if text.isEmpty {
            post(51 /* Delete */, down: true); post(51, down: false)
        } else {
            Paste.insert(text)
        }
    }
}
