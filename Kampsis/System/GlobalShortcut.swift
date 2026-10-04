import AppKit
import Carbon.HIToolbox

enum ShortcutFailure: LocalizedError {
    case handlerRejected(OSStatus)
    case keyTaken(label: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case let .handlerRejected(status):
            String(localized: "Couldn’t set up the global shortcut (code \(status)).")
        case let .keyTaken(label, status):
            String(localized: "\(label) is already used by another app (code \(status)). Choose another shortcut or toggle the effect from the menu.")
        }
    }
}

/// глобальное сочетание через Carbon: работает без разрешения на мониторинг ввода
@MainActor final class GlobalShortcut {
    private static let signature: OSType = 0x4C44_464C
    let value: ToggleShortcut
    private let onPress: () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(_ shortcut: ToggleShortcut, onPress: @escaping () -> Void) throws {
        value = shortcut
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
        let registered = RegisterEventHotKey(UInt32(shortcut.keyCode), carbonModifiers(shortcut.modifiers),
                                             EventHotKeyID(signature: Self.signature, id: 1),
                                             GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registered == noErr else {
            throw ShortcutFailure.keyTaken(label: shortcutLabel(shortcut), status: registered)
        }
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}

private func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
    [(ShortcutModifiers.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        .filter { modifiers.contains($0.0) }
        .reduce(0) { $0 | UInt32($1.1) }
}

/// модификаторы сочетания из нажатия клавиши
func shortcutModifiers(_ flags: NSEvent.ModifierFlags) -> ShortcutModifiers {
    [(NSEvent.ModifierFlags.control, ShortcutModifiers.control), (.option, .option), (.shift, .shift), (.command, .command)]
        .filter { flags.contains($0.0) }
        .reduce([]) { $0.union($1.1) }
}

/// подпись сочетания для меню и настроек, например ⌘⌥B
@MainActor func shortcutLabel(_ shortcut: ToggleShortcut) -> String {
    shortcut.modifierSymbols + keyLabel(keyCode: shortcut.keyCode)
}

private let specialKeyLabels: [Int: String] = [
    kVK_Space: String(localized: "Space"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
    kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
    kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
]

/// символ клавиши в латинской раскладке, чтобы подпись не менялась при переключении языка ввода
@MainActor private func keyLabel(keyCode: UInt16) -> String {
    if let special = specialKeyLabels[Int(keyCode)] { return special }
    let unknown = "#\(keyCode)"
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return unknown }
    let layoutData = Unmanaged<CFData>.fromOpaque(layout).takeUnretainedValue() as Data
    var deadKeyState: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)
    let status = layoutData.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return OSStatus(paramErr) }
        return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), keyCode, UInt16(kUCKeyActionDisplay),
                              0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                              &deadKeyState, characters.count, &length, &characters)
    }
    guard status == noErr, length > 0 else { return unknown }
    return String(utf16CodeUnits: characters, count: length).uppercased()
}
