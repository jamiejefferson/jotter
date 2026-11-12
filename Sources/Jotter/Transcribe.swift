import AVFoundation
import Foundation
import Speech

/// Transcribes a recording folder on the Mac with Apple's speech engine and
/// writes `transcript.md` beside the audio. Each track is transcribed on its
/// own; the mic is labelled "You" and the call track "Call", then the two are
/// merged by time.
///
///   Jotter --transcribe <recording folder> [locale]
enum Transcribe {
    struct Line {
        let start: Double
        let end: Double
        let who: String
        let text: String
    }

    static func run(_ args: [String]) -> Bool {
        guard args.count > 2, args[1] == "--transcribe" else { return false }
        let folder = URL(fileURLWithPath: args[2])
        let wanted = args.count > 3 ? args[3] : "en-GB"
        guard #available(macOS 26.0, *) else {
            print("FAILED: Apple's on-device transcription needs macOS 26.")
            exit(1)
        }
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                try await transcribe(folder: folder, wanted: wanted)
            } catch {
                print("FAILED: \(error.localizedDescription)")
                exit(1)
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    @available(macOS 26.0, *)
    static func transcribe(folder: URL, wanted: String) async throws {
        let supported = await SpeechTranscriber.supportedLocales
        let candidates = [Locale(identifier: wanted), Locale(identifier: "en-GB"), Locale(identifier: "en-US")]
        guard let locale = candidates.first(where: { c in
            supported.contains { $0.identifier(.bcp47) == c.identifier(.bcp47) }
        }) else { throw CaptureError(message: "No supported English locale.") }
        print("locale: \(locale.identifier(.bcp47))")

        let probe = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            print("downloading speech model…")
            try await request.downloadAndInstall()
        }

        let info = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("info.json")))) as? [String: Any]
        // Each track's clock starts at its first sample. The call track starts when the Mac first
        // plays sound, often well after the mic, so shift it to line up with the mic.
        var offsets: [String: Double] = [:]
        let iso = ISO8601DateFormatter()
        let firsts = ((info?["tracks"] as? [[String: Any]]) ?? []).reduce(into: [String: Date]()) { acc, t in
            if let n = t["name"] as? String, let f = t["firstSampleAt"] as? String, let d = iso.date(from: f) { acc[n] = d }
        }
        if let m = firsts["mic"], let c = firsts["call"] { offsets["Call"] = c.timeIntervalSince(m) }

        var lines: [Line] = []
        var timings: [String] = []
        for (file, who) in [("mic.m4a", "You"), ("call.m4a", "Call")] {
            let url = folder.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let t0 = Date()
            let got = try await transcribeFile(url, who: who, locale: locale)
            let seconds = Date().timeIntervalSince(t0)
            let audio = try AVAudioFile(forReading: url)
            let length = Double(audio.length) / audio.processingFormat.sampleRate
            timings.append("\(who): \(Int(length.rounded())) s of audio in \(String(format: "%.1f", seconds)) s")
            print("\(who): \(got.count) segments, \(String(format: "%.1f", seconds)) s")
            let shift = offsets[who] ?? 0
            lines += got.map { Line(start: $0.start + shift, end: $0.end + shift, who: $0.who, text: $0.text) }
        }
        // Paused spans recorded silence; mark them so the transcript shows the gap.
        let pauses = ((info?["pauses"] as? [[String: Any]]) ?? []).compactMap { p -> (Double, Double)? in
            guard let f = p["from"] as? Double, let t = p["to"] as? Double else { return nil }
            return (f, t)
        }
        for (f, t) in pauses {
            lines.append(Line(start: f, end: f, who: "Paused", text: "Paused for \(clock(t - f)) (\(clock(f)) to \(clock(t))), off the record."))
        }
        lines.sort { $0.start < $1.start }

        var md: [String] = []
        md.append("---")
        md.append("source: jotter")
        md.append("recording: \"\(folder.lastPathComponent)\"")
        if let started = info?["startedAt"] as? String { md.append("started: \(started)") }
        if let project = info?["project"] as? String, !project.isEmpty { md.append("project: \(project)") }
        if !pauses.isEmpty { md.append("pauses: \(pauses.count)") }
        md.append("engine: Apple SpeechTranscriber (on-device)")
        md.append("locale: \(locale.identifier(.bcp47))")
        md.append("created: \(ISO8601DateFormatter().string(from: Date()))")
        md.append("---")
        md.append("# Transcript — \(folder.lastPathComponent)")
        md.append("")
        md.append("\"You\" is the laptop microphone; \"Call\" is everyone heard through the Mac. Speaker names inside the call aren't separated yet.")
        md.append("")
        md.append("Transcription time: " + timings.joined(separator: "; ") + ".")
        md.append("")
        // Join consecutive segments from the same side into one paragraph.
        var current: Line?
        var buffer: [String] = []
        func flush() {
            guard let c = current else { return }
            if c.who == "Paused" {
                md.append("*\(buffer.joined(separator: " "))*")
            } else {
                md.append("**\(c.who)** [\(clock(c.start))] \(buffer.joined(separator: " "))")
            }
            md.append("")
        }
        for line in lines {
            if let c = current, c.who == line.who, line.start - c.end < 4 {
                buffer.append(line.text)
                current = Line(start: c.start, end: line.end, who: c.who, text: "")
            } else {
                flush()
                current = line
                buffer = [line.text]
            }
        }
        flush()
        let out = folder.appendingPathComponent("transcript.md")
        try md.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        print("wrote \(out.path)")
    }

    @available(macOS 26.0, *)
    static func transcribeFile(_ url: URL, who: String, locale: Locale) async throws -> [Line] {
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () -> [Line] in
            var out: [Line] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                out.append(Line(start: result.range.start.seconds, end: result.range.end.seconds, who: who, text: text))
            }
            return out
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collect.value
    }

    static func clock(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
