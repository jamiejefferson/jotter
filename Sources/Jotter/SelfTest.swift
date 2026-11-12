import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import Foundation

/// Command-line checks used during development:
///   Jotter --selftest-writer <folder>       writes a 440 Hz tone for 3 s, then waits (kill it to test crash recovery)
///   Jotter --selftest-recover               compresses any unfinished recordings
///   Jotter --selftest-call <seconds> <folder>
///   Jotter --selftest-mic <seconds> <folder>
///   Jotter --selftest-dictate <audio file>
///       streams the file at real-time pace through the dictation engine and prints the
///       text and the delay from the end of the audio to the final text
enum SelfTest {
    static func run(_ args: [String]) -> Bool {
        guard args.count > 1, args[1].hasPrefix("--selftest") else { return false }
        do {
            switch args[1] {
            case "--selftest-writer": try writer(URL(fileURLWithPath: args[2]))
            case "--selftest-recover": Store.recoverUnfinished(); print("recovered")
            case "--selftest-call": try capture(call: true, seconds: Double(args[2]) ?? 5, URL(fileURLWithPath: args[3]))
            case "--selftest-call-headset":
                // Opens the default input the way a video-call app does, which puts
                // Bluetooth headphones into hands-free mode, then records call audio.
                let hold = try HoldInput()
                defer { hold.stop() }
                try capture(call: true, seconds: Double(args[2]) ?? 5, URL(fileURLWithPath: args[3]))
            case "--selftest-dictate":
                guard #available(macOS 26.0, *) else { print("needs macOS 26"); exit(1) }
                dictate(URL(fileURLWithPath: args[2]))
            case "--selftest-tidy":
                // Jotter --selftest-tidy "<text>": prints Light and Tidy versions and the time Tidy took.
                let raw = Vocabulary.apply(args[2])
                print("light: \(Cleanup.light(raw))")
                let done = DispatchSemaphore(value: 0)
                Task {
                    let t0 = Date()
                    do { let out = try await Cleanup.tidy(raw); print(String(format: "tidy (%.2f s): ", Date().timeIntervalSince(t0)) + out) }
                    catch { print("tidy FAILED: \(error.localizedDescription)") }
                    done.signal()
                }
                while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            case "--selftest-correct":
                // Jotter --selftest-correct "<text>" "<spoken instruction>"
                let done = DispatchSemaphore(value: 0)
                Task {
                    let t0 = Date()
                    do {
                        let out = try await Cleanup.correct(args[2], instruction: Vocabulary.apply(args[3]))
                        print(String(format: "%.2f s: ", Date().timeIntervalSince(t0)) + (out.text.isEmpty ? "(deleted)" : out.text))
                        print("   misheard: " + (out.misheard.isEmpty ? "none" : out.misheard.map { "\($0.heard) => \($0.meant)" }.joined(separator: "; ")))
                    }
                    catch { print("FAILED: \(error.localizedDescription)") }
                    done.signal()
                }
                while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            case "--selftest-learn":
                // Jotter --selftest-learn "<heard>" "<meant>": adds a fix to vocabulary.txt and shows the effect.
                print("learned: \(Vocabulary.learn(heard: args[2], meant: args[3]))")
                print("now: \(Vocabulary.apply("Meet \(args[2]) on Friday."))")
            case "--selftest-replace":
                // open -n Jotter.app --args --selftest-replace <result file>
                // After 4 s, pastes a sentence into the front app, steps back over it with Shift+Left
                // and pastes a corrected one, as a correction in a browser-based app does.
                let out = URL(fileURLWithPath: args[2])
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    let original = "Hi there, can you take a note of some things?"
                    Paste.insert(original)
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
                    await Editing.replace(Editing.Target(text: original, pid: pid, how: .lastDictationByKeys),
                                          with: "Hi there, can you take a note of some cars?")
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    var value = "(unreadable)"
                    var f: CFTypeRef?
                    if AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &f) == .success, let f {
                        var v: CFTypeRef?
                        if AXUIElementCopyAttributeValue(f as! AXUIElement, kAXValueAttribute as CFString, &v) == .success, let str = v as? String { value = str }
                    }
                    try? "trusted=\(AXIsProcessTrusted()) app=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")\nvalue=\(value)\n".write(to: out, atomically: true, encoding: .utf8)
                    done.signal()
                }
                while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            case "--selftest-notes":
                // Jotter --selftest-notes <recording folder>: writes and files notes for a recording.
                let done = DispatchSemaphore(value: 0)
                Task {
                    let t0 = Date()
                    do { let note = try await MeetingNotes.generate(folder: URL(fileURLWithPath: args[2])); print(String(format: "%.0f s: ", Date().timeIntervalSince(t0)) + note.path) }
                    catch { print("FAILED: \(error.localizedDescription)") }
                    done.signal()
                }
                while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            case "--selftest-doubletap":
                // open -n Jotter.app --args --selftest-doubletap: taps the dictation key twice, as JJ would.
                let src = CGEventSource(stateID: .hidSystemState)
                for _ in 0..<2 {
                    for down in [true, false] {
                        let e = CGEvent(keyboardEventSource: src, virtualKey: HoldKey.current.keyCode, keyDown: down)
                        e?.type = .flagsChanged
                        e?.flags = down ? CGEventFlags(rawValue: HoldKey.current.eventFlags) : []
                        e?.post(tap: .cghidEventTap)
                        usleep(down ? 80_000 : 120_000)
                    }
                }
            case "--selftest-mic": try capture(call: false, seconds: Double(args[2]) ?? 5, URL(fileURLWithPath: args[3]))
            default: print("unknown self-test")
            }
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
        return true
    }

    private static func writer(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let w = try TrackWriter(folder: folder, name: "mic", sampleRate: 48_000)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        var phase = 0.0
        for _ in 0..<(3 * 48_000 / 4800) {
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
            b.frameLength = 4800
            for i in 0..<4800 {
                let s = Float(sin(phase) * 0.5)
                b.floatChannelData![0][i] = s
                b.floatChannelData![1][i] = s
                phase += 2 * .pi * 440 / 48_000
            }
            if phase < 2 * .pi * 440 * 0.15 {   // one 7x full-scale spike, like the built-in mic produces
                b.floatChannelData![0][100] = 7
                b.floatChannelData![1][100] = 7
            }
            w.appendMixing(b)
            Thread.sleep(forTimeInterval: 0.1)
        }
        print("wrote 3s; waiting to be killed")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 600)
    }

    private static func capture(call: Bool, seconds: Double, _ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writer: TrackWriter?
        let stop: () -> Void
        if call {
            let c = CallCapture()
            try c.start(folder: folder)
            writer = c.writer
            stop = c.stop
        } else {
            let m = MicCapture()
            try m.start(folder: folder)
            writer = m.writer
            stop = m.stop
        }
        var peak: Float = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            peak = max(peak, writer?.takePeak() ?? 0)
        }
        stop()
        guard let r = writer?.finish() else { print("no writer"); return }
        let out = try TrackWriter.compress(r.caf)
        print("rateChanges=\(r.rateChanges)")
        print("track=\(r.name) rate=\(r.sampleRate) seconds=\(String(format: "%.1f", Double(r.frames) / r.sampleRate)) peak=\(String(format: "%.3f", peak)) heard=\(r.heardSound) file=\(out.url.path)")
    }
    @available(macOS 26.0, *)
    private static func dictate(_ url: URL) {
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                let t0 = Date()
                let setup = try await DictationSession.prepare()
                print(String(format: "setup: %.2f s (%@)", Date().timeIntervalSince(t0), setup.locale.identifier(.bcp47)))
                let file = try AVAudioFile(forReading: url)
                let fmt = file.processingFormat
                // Three presses, as in real use: the first shows cold start, the others warm.
                for press in 1...3 {
                    file.framePosition = 0
                    let t1 = Date()
                    let s = DictationSession(setup)
                    let chunk = AVAudioFrameCount(fmt.sampleRate / 10)
                    while file.framePosition < file.length {
                        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk)!
                        try file.read(into: b, frameCount: chunk)
                        s.feed(b)
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    let audio = Date().timeIntervalSince(t1)
                    let t2 = Date()
                    let text = try await s.finish()
                    print(String(format: "press %d: %.1f s of audio, text %.2f s after release", press, audio, Date().timeIntervalSince(t2)))
                    if press == 1 { print("heard: \(text)\nfixed: \(Vocabulary.apply(text))") }
                }
            } catch {
                print("FAILED: \(error.localizedDescription)")
                exit(1)
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}

/// Keeps the default input device running, as a call app would.
final class HoldInput {
    private let id: AudioDeviceID
    private var proc: AudioDeviceIOProcID?
    init() throws {
        guard let id = AudioDevices.defaultInput() else { throw CaptureError(message: "No default input.") }
        self.id = id
        print("holding input: \(AudioDevices.name(id) ?? "?")")
        AudioDeviceCreateIOProcIDWithBlock(&proc, id, DispatchQueue(label: "hold")) { _, _, _, _, _ in }
        AudioDeviceStart(id, proc)
        Thread.sleep(forTimeInterval: 1.5)
    }
    func stop() {
        if let proc { AudioDeviceStop(id, proc); AudioDeviceDestroyIOProcID(id, proc) }
    }

}
