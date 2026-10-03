/// модификаторы сочетания клавиш
struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    static let control = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let shift = ShortcutModifiers(rawValue: 1 << 2)
    static let command = ShortcutModifiers(rawValue: 1 << 3)
}

/// глобальное сочетание, которое включает и выключает эффект: код физической клавиши и модификаторы
struct ToggleShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifiers: ShortcutModifiers

    /// ⌘⌥B, код 11 у клавиши B в любой раскладке
    static let standard = ToggleShortcut(keyCode: 11, modifiers: [.command, .option])

    /// без ⌘, ⌥ или ⌃ сочетание перехватывало бы обычный набор текста
    var isAcceptable: Bool { !modifiers.isDisjoint(with: [.command, .option, .control]) }

    /// значки модификаторов в порядке, принятом в меню macOS
    var modifierSymbols: String {
        [(ShortcutModifiers.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { modifiers.contains($0.0) }
            .map(\.1)
            .joined()
    }
}
