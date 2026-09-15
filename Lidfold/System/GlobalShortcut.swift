import Carbon.HIToolbox

enum ShortcutFailure: LocalizedError {
    case handlerRejected(OSStatus)
    case keyTaken(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .handlerRejected(status): String(localized: "The ⌘⌥B shortcut couldn’t be set up (code \(status)).")
        case .keyTaken: String(localized: "⌘⌥B is already used by another app. You can still toggle the effect from the menu.")
        }
    }
}

/// глобальное сочетание ⌘⌥B через Carbon: работает без разрешения на мониторинг ввода
@MainActor final class GlobalShortcut {
    private static let signature: OSType = 0x4C44_464C
    private let onPress: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(onPress: @escaping () -> Void) throws {
        self.onPress = onPress
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let owner = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue().onPress()
            }
            return noErr
        }, 1, &pressed, owner, &eventHandler)
        guard handlerStatus == noErr else { throw ShortcutFailure.handlerRejected(handlerStatus) }
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | optionKey),
                                             EventHotKeyID(signature: Self.signature, id: 1),
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registered == noErr else { throw ShortcutFailure.keyTaken(registered) }
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
