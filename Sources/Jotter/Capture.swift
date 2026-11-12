import AVFoundation
import CoreAudio

struct CaptureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CaptureError(message: "Couldn't \(what) (Core Audio error \(status)).") }
}

// MARK: - Microphone

/// Records the Mac's built-in microphone straight from Core Audio, whatever the
/// system's default input is. Opening the built-in mic leaves Bluetooth earbuds
/// alone, so they don't drop into their low-quality call mode.
final class MicCapture: @unchecked Sendable {
    private var deviceID = AudioDeviceID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.eqtr.jotter.mic", qos: .userInitiated)
    private(set) var writer: TrackWriter?
    private(set) var deviceName = ""

    func start(folder: URL) throws {
        guard let id = AudioDevices.builtInInput() ?? AudioDevices.defaultInput() else {
            throw CaptureError(message: "No microphone is available.")
        }
        deviceID = id
        deviceName = AudioDevices.name(id) ?? "Microphone"
        guard var asbd = AudioDevices.inputFormat(id),
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError(message: "Couldn't read the microphone's format.")
        }
        let w = try TrackWriter(folder: folder, name: "mic", sampleRate: format.sampleRate)
        writer = w
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, id, queue) { _, input, _, _, _ in
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
            else { return }
            w.appendMixing(buf)
        }, "attach to the microphone")
        try check(AudioDeviceStart(id, procID), "start the microphone")
    }

    func stop() {
        if let procID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
    }
}

// MARK: - Call audio

/// Records everything the Mac is playing (the call's remote voices) through a
/// Core Audio process tap. No meeting bot, no screen recording, and it works
/// whether sound goes to speakers or headphones.
final class CallCapture: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.eqtr.jotter.call", qos: .userInitiated)
    private(set) var writer: TrackWriter?
    private let formatLock = NSLock()
    private var format: AVAudioFormat?
    private var formatListener: AudioObjectPropertyListenerBlock?

    private static let formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                                  mElement: kAudioObjectPropertyElementMain)

    /// The tap's current format. It can change mid-call, for example when
    /// Bluetooth headphones switch into hands-free mode.
    private func readFormat() -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = Self.formatAddress
        guard AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }

    func start(folder: URL) throws {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.name = "Jotter call audio"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create the call audio tap")

        guard let format = readFormat() else {
            throw CaptureError(message: "Couldn't read the call audio format.")
        }
        self.format = format
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let f = self.readFormat() else { return }
            self.formatLock.lock(); self.format = f; self.formatLock.unlock()
        }
        var addr = Self.formatAddress
        AudioObjectAddPropertyListenerBlock(tapID, &addr, queue, listener)
        formatListener = listener

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Jotter call capture",
            kAudioAggregateDeviceUIDKey: "com.eqtr.jotter.call.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                  "create the call capture device")

        let w = try TrackWriter(folder: folder, name: "call", sampleRate: format.sampleRate)
        writer = w
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { [weak self] _, input, _, _, _ in
            guard let self else { return }
            self.formatLock.lock(); let current = self.format; self.formatLock.unlock()
            guard let current,
                  let buf = AVAudioPCMBuffer(pcmFormat: current, bufferListNoCopy: input, deallocator: nil)
            else { return }
            w.appendMixing(buf)
        }, "attach to the call capture device")
        try check(AudioDeviceStart(aggregateID, procID), "start capturing call audio")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            if let formatListener {
                var addr = Self.formatAddress
                AudioObjectRemovePropertyListenerBlock(tapID, &addr, queue, formatListener)
            }
            AudioHardwareDestroyProcessTap(tapID)
        }
        formatListener = nil
        procID = nil
        aggregateID = kAudioObjectUnknown
        tapID = kAudioObjectUnknown
    }
}

// MARK: - Devices

enum AudioDevices {
    static func builtInInput() -> AudioDeviceID? {
        allDevices().first { hasInput($0) && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
    }

    static func defaultInput() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != kAudioObjectUnknown else { return nil }
        return dev
    }

    /// The format Core Audio delivers for the device's first input stream.
    static func inputFormat(_ dev: AudioDeviceID) -> AudioStreamBasicDescription? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &streams) == noErr, let first = streams.first
        else { return nil }
        var fAddr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var fSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(first, &fAddr, 0, nil, &fSize, &asbd) == noErr else { return nil }
        return asbd
    }

    static func name(_ dev: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    private static func allDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ dev: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func transportType(_ dev: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &type)
        return type
    }
}
