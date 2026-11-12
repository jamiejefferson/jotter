import AVFoundation

/// Writes one audio track to disk as it arrives.
///
/// While recording, samples go to a 32-bit float `.caf` file, which stays readable
/// if the app crashes or the Mac loses power. When the recording stops, the file
/// is compressed to `.m4a` (AAC, about 45 MB an hour) and the `.caf` is removed.
/// A `.caf` left behind by a crash is compressed on the next launch.
final class TrackWriter: @unchecked Sendable {
    let name: String
    let cafURL: URL
    let format: AVAudioFormat

    private var file: AVAudioFile?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var peakSinceRead: Float = 0
    private var everHeard = false
    private var frames: AVAudioFramePosition = 0
    private var firstSampleAt: Date?
    private var writeError: String?
    private var resampler: AVAudioConverter?
    private(set) var rateChanges = 0
    private var silenced = false

    /// While paused the track keeps running but records silence, so both tracks stay
    /// in step with the meeting clock and nothing said in the pause is kept.
    var paused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return silenced }
        set { lock.lock(); silenced = newValue; lock.unlock() }
    }

    init(folder: URL, name: String, sampleRate: Double) throws {
        self.name = name
        cafURL = folder.appendingPathComponent("\(name).caf")
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                               channels: 1, interleaved: false)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(forWriting: cafURL, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        queue = DispatchQueue(label: "com.eqtr.jotter.writer.\(name)", qos: .userInitiated)
    }

    /// Takes a float buffer of any channel count and sample rate, mixes it to mono,
    /// and queues it for writing. Audio at another rate (Bluetooth headphones
    /// dropping into call mode, say) is resampled to the file's rate on the
    /// writer queue. Safe to call from a realtime audio thread.
    func appendMixing(_ b: AVAudioPCMBuffer) {
        let n = Int(b.frameLength)
        let rate = b.format.sampleRate
        guard n > 0, rate > 0, let src = b.floatChannelData,
              let monoFormat = rate == format.sampleRate ? format
                  : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(n))
        else { return }
        out.frameLength = AVAudioFrameCount(n)
        let dst = out.floatChannelData![0]
        let ch = max(1, Int(b.format.channelCount))
        let scale = 1 / Float(ch)
        var peak: Float = 0
        if paused {
            for i in 0..<n { dst[i] = 0 }
        } else if b.format.isInterleaved {
            let p = src[0]
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<ch { s += p[i * ch + c] }
                s *= scale
                dst[i] = s
                peak = max(peak, abs(s))
            }
        } else {
            for i in 0..<n {
                var s: Float = 0
                for c in 0..<ch { s += src[c][i] }
                s *= scale
                dst[i] = s
                peak = max(peak, abs(s))
            }
        }
        lock.lock()
        peakSinceRead = max(peakSinceRead, peak)
        if peak > 0.002 { everHeard = true }
        if firstSampleAt == nil { firstSampleAt = Date() }
        lock.unlock()

        queue.async { [weak self] in
            guard let self, let file = self.file else { return }
            do {
                let ready = try self.toFileRate(out)
                guard ready.frameLength > 0 else { return }
                try file.write(from: ready)
                self.frames += AVAudioFramePosition(ready.frameLength)
            } catch {
                self.writeError = error.localizedDescription
            }
        }
    }

    /// Runs on the writer queue. Keeps one converter per incoming rate so the
    /// resampler's state carries across buffers without clicks.
    private func toFileRate(_ buf: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard buf.format.sampleRate != format.sampleRate else { return buf }
        if resampler?.inputFormat.sampleRate != buf.format.sampleRate {
            resampler = AVAudioConverter(from: buf.format, to: format)
            rateChanges += 1
        }
        guard let resampler else { throw CaptureError(message: "Couldn't resample \(Int(buf.format.sampleRate)) Hz audio.") }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * format.sampleRate / buf.format.sampleRate) + 64
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap)!
        var fed = false
        var err: NSError?
        let status = resampler.convert(to: out, error: &err) { _, inStatus in
            if fed { inStatus.pointee = .noDataNow; return nil }
            fed = true
            inStatus.pointee = .haveData
            return buf
        }
        if status == .error, let err { throw err }
        return out
    }

    /// Loudest sample since the last call, 0 to 1. Resets on read.
    func takePeak() -> Float {
        lock.lock(); defer { lock.unlock() }
        let p = peakSinceRead
        peakSinceRead = 0
        return p
    }

    var heardSound: Bool {
        lock.lock(); defer { lock.unlock() }
        return everHeard
    }

    struct Result {
        let name: String
        let caf: URL
        let frames: AVAudioFramePosition
        let sampleRate: Double
        let rateChanges: Int
        let firstSampleAt: Date?
        let heardSound: Bool
        let error: String?
    }

    /// Flushes queued audio and closes the `.caf`.
    func finish() -> Result {
        queue.sync { file = nil }
        lock.lock(); defer { lock.unlock() }
        return Result(name: name, caf: cafURL, frames: frames, sampleRate: format.sampleRate, rateChanges: rateChanges,
                      firstSampleAt: firstSampleAt, heardSound: everHeard, error: writeError)
    }

    /// Compresses a `.caf` to `.m4a` beside it and deletes the `.caf`.
    /// Leaves the `.caf` in place if anything fails, so no audio is lost.
    @discardableResult
    static func compress(_ caf: URL) throws -> (url: URL, seconds: Double) {
        let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
        let seconds: Double
        do {
            let src = try AVAudioFile(forReading: caf)
            let rate = src.processingFormat.sampleRate
            seconds = Double(src.length) / rate
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: Int(src.processingFormat.channelCount),
                AVEncoderBitRateKey: 96_000,
            ]
            try? FileManager.default.removeItem(at: m4a)
            let dst = try AVAudioFile(forWriting: m4a, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 1 << 16)!
            // Single-sample spikes from the built-in mic can exceed full scale. Limit only
            // the samples near or above full scale; the rest of the track keeps its level.
            while src.framePosition < src.length {
                try src.read(into: buf)
                if buf.frameLength == 0 { break }
                for c in 0..<Int(buf.format.channelCount) {
                    let p = buf.floatChannelData![c]
                    for i in 0..<Int(buf.frameLength) { p[i] = TrackWriter.softLimit(p[i]) }
                }
                try dst.write(from: buf)
            }
        }
        // Both files are closed here; check the result before removing the original.
        let check = try AVAudioFile(forReading: m4a)
        let kept = Double(check.length) / check.processingFormat.sampleRate
        guard seconds == 0 || kept >= seconds - 1 else {
            throw NSError(domain: "Jotter", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Compressed file is shorter than the recording (\(Int(kept))s of \(Int(seconds))s); kept the original."])
        }
        try FileManager.default.removeItem(at: caf)
        return (m4a, seconds)
    }

    /// Leaves samples under 0.9 untouched and bends anything louder smoothly towards 1.
    static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > 0.9 else { return x }
        return (x < 0 ? -1 : 1) * (0.9 + 0.1 * tanh((a - 0.9) / 0.1))
    }
}
