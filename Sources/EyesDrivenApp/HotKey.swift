import Carbon.HIToolbox
import Foundation

/// A global hotkey registered through Carbon `RegisterEventHotKey`. It needs no
/// Accessibility permission and fires even while another app is frontmost. The
/// handler is always invoked on the main thread.
///
/// Carbon event handling is main-thread work, so the whole type is `@MainActor`.
@MainActor
final class HotKey {

    private static var nextID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let identifier: UInt32
    private let handler: () -> Void

    /// Registers a hotkey for `keyCode` (a virtual key code such as
    /// `kVK_ANSI_E`) with Carbon `modifiers` (e.g. `controlKey | optionKey |
    /// cmdKey`). The handler runs on the main thread.
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        self.handler = handler
        self.identifier = HotKey.nextID
        HotKey.nextID += 1

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        _ = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                var pressedID = EventHotKeyID()
                _ = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                guard pressedID.id == hotKey.identifier else { return noErr }
                DispatchQueue.main.async { hotKey.handler() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: HotKey.signature, id: identifier)
        _ = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { _ = UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { _ = RemoveEventHandler(eventHandlerRef) }
    }

    /// The default pause/resume toggle: ⌃⌥⌘E.
    static func defaultToggle(handler: @escaping () -> Void) -> HotKey {
        HotKey(
            keyCode: UInt32(kVK_ANSI_E),
            modifiers: UInt32(controlKey | optionKey | cmdKey),
            handler: handler
        )
    }

    private static let signature: OSType = {
        var value: OSType = 0
        for byte in "ED2m".utf8 { value = (value << 8) | OSType(byte) }
        return value
    }()
}
