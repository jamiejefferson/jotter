import Carbon.HIToolbox
import Foundation

/// A single system-wide hotkey via Carbon's RegisterEventHotKey. Unlike an
/// NSEvent global monitor, this needs no Accessibility permission — important,
/// because the Mute-r kill-switch must work even before the user has granted
/// anything else.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onFire: () -> Void

    private static var instances: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1
    private let id: UInt32

    /// - Parameters:
    ///   - keyCode: a `kVK_…` virtual key code (e.g. `kVK_ANSI_M`).
    ///   - modifiers: Carbon modifier mask (e.g. `controlKey | optionKey | cmdKey`).
    init(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
        self.onFire = onFire
        self.id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.instances[id] = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKey.instances[hkID.id]?.onFire()
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let hkID = EventHotKeyID(signature: OSType(0x4A4F5454 /* 'JOTT' */), id: id)
        RegisterEventHotKey(keyCode, modifiers, hkID,
                            GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        HotKey.instances[id] = nil
    }
}
